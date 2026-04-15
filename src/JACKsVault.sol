// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JACKs Reward Vault - Buyer Round Distribution
 * @notice Core vault of the JACKs Pools ecosystem, holding and distributing
 *         round-based rewards using a secure pull-payment system.
 * @dev Features adaptive thresholds based on total LP value and ensures
 *      full payout to the selected recipient without external control or intervention.
 */

interface IJACKsPools {
    function getLpValue() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract JACKsVault is ReentrancyGuard {
    IJACKsPools public immutable TOKEN;
	
	// Dual buffer system for eligible buyers
	struct BuyEntry {
		address buyer;
		uint256 amount;
		uint256 timestamp;
	}

	// 8-buffer rotation system — max 512 active tickets per round
	struct BufferSet {
		BuyEntry[512] entries;  // 512 slots per buffer
		uint256 size;           // Current entries in this buffer
		uint256 index;          // Next write position (circular)
	}

	BufferSet[8] public buffers;  // 8 buffers in rotation, 512 slots each

	// Buffer tracking
	uint256 public activeBufferNum;    // 0-7 (which buffer is currently active)
	uint256 public snapshotBufferNum;  // Which buffer is frozen for drawing

	// Round tracking
	uint256 public currentRound;
	mapping(address => uint256) public lastTicketRound;

	// Snapshot state
	bool public snapshotTaken;
	uint256 public snapshotTimestamp;
	uint256 public snapshotRound;
	uint256 public snapshotBlockNumber;      // Block when snapshot taken
	uint256 public snapshotRevealBlock;       // Block when can finalize
	uint256 public snapshotThreshold;         // Threshold cached at snapshot time
	mapping(uint256 => bytes32) public roundEntropy; // Community entropy per round

	// Constants for buffer system
	uint256 public constant BUFFER_CAPACITY = 512;
	uint256 public constant BUFFER_COUNT = 8;
	uint256 public constant TOTAL_CAPACITY = 4096;  // 8 x 512 total rotation capacity
	// NOTE: max active tickets per single round is BUFFER_CAPACITY (512)
	// The 8 buffers provide rotation between rounds, not concurrent capacity per round	
	uint256 public constant ENTRY_EXPIRY = 2 hours;
    
    // Configuration
	uint256 public constant MAX_CLAIM_DELAY = 30 days; // Safety: auto-release after 30 days
	uint256 public constant FINALIZE_COOLDOWN = 3 minutes;
	uint256 public constant REVEAL_DELAY_BLOCKS = 25;
	
	// Stage LP thresholds
	uint256 private constant STAGE_2_LP_THRESHOLD = 10 ether;
	uint256 private constant STAGE_3_LP_THRESHOLD = 50 ether;
	uint256 private constant STAGE_4_LP_THRESHOLD = 150 ether;
	uint256 private constant STAGE_5_LP_THRESHOLD = 500 ether;

	// Stage 1: Pool thresholds (LP < 10 ETH)
	uint256 private constant STAGE_1_POOL_THRESHOLD = 0.15 ether;
	uint256 private constant STAGE_1_MIN_BUY = 0.00043 ether;       // $1.50 @ $3500/ETH
	uint256 private constant STAGE_1_MIN_TOKENS = 500_000 * 10**18; // 500k tokens

	// Stage 2: Pool thresholds (LP 10-50 ETH)
	uint256 private constant STAGE_2_POOL_THRESHOLD = 0.3 ether; 
	uint256 private constant STAGE_2_MIN_BUY = 0.00057 ether;       // $2 @ $3500/ETH
	uint256 private constant STAGE_2_MIN_TOKENS = 250_000 * 10**18; // 250k tokens

	// Stage 3: Pool thresholds (LP 50-150 ETH)
	uint256 private constant STAGE_3_POOL_THRESHOLD = 0.75 ether;
	uint256 private constant STAGE_3_MIN_BUY = 0.00071 ether;       // $2.50 @ $3500/ETH
	uint256 private constant STAGE_3_MIN_TOKENS = 100_000 * 10**18; // 100k tokens

	// Stage 4: Pool thresholds (LP 150-500 ETH)
	uint256 private constant STAGE_4_POOL_THRESHOLD = 1 ether;
	uint256 private constant STAGE_4_MIN_BUY = 0.00086 ether;       // $3 @ $3500/ETH
	uint256 private constant STAGE_4_MIN_TOKENS = 50_000 * 10**18;  // 50k tokens

	// Stage 5: Pool thresholds (LP > 500 ETH)
	uint256 private constant STAGE_5_POOL_THRESHOLD = 2 ether;
	uint256 private constant STAGE_5_MIN_BUY = 0.001 ether;         // $3.50 @ $3500/ETH
	uint256 private constant STAGE_5_MIN_TOKENS = 1 * 10**18;       // 1 token
    
    // State
    uint256 public payoutRound;
    uint256 public totalDistributed;
    uint256 public totalClaimed;
	uint256 public lastFinalizeTime;
    mapping(address => uint256[]) private userRounds;
    mapping(address => uint256) public recipientHistory;
    mapping(uint256 => RoundInfo) public rounds;
	mapping(address => address payable) public payoutAddress; // Payout address redirection (for contract wallets)
	
	// Winner tracking (for statistics)
	address[] private uniqueRecipients;
	mapping(address => bool) private hasReceivedBefore;
	uint256 public largestReward;
	    
    struct RoundInfo {
		address recipient;
		uint256 amount;
		uint256 timestamp;
		bool claimed;
	}
    
    // Security
    address public owner;
        
    // Events
    event Funded(address indexed from, uint256 amount, uint256 poolAfter);
	event BuyerAdded(address indexed buyer, uint256 amount, uint256 round);
	event SnapshotTaken(uint256 timestamp, uint256 entries, uint256 round);
	event BufferSwapped(uint256 newActiveBufferNum, uint256 round);
    event RoundReady(uint256 poolBalance, uint256 eligibleBuyers, uint256 round);
    event RewardDistributed(address indexed recipient, uint256 amount, uint256 round);
    event RewardClaimed(address indexed claimant, address indexed recipient, uint256 indexed roundId, uint256 amount);
	event PayoutAddressSet(address indexed user, address indexed payoutAddress);
	event SnapshotReset(uint256 indexed round, string reason);
	event RoundSkippedNoEligibleWinners(uint256 indexed round, uint256 entriesChecked, uint256 poolReturned);
	event RoundExpiredBlockhashStale(uint256 indexed round, uint256 snapshotBlock, uint256 currentBlock);
	event SnapshotAutoResetTimeout(uint256 indexed round, uint256 snapshotTimestamp, uint256 resetTimestamp);
	event ExpiredClaimCleaned(uint256 indexed round, uint256 recoveredAmount);
    event OwnershipRenounced();
    
    modifier onlyToken() {
        require(msg.sender == address(TOKEN), "Only token");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
        
    constructor(address _token) {
        require(_token != address(0), "Zero token");
        
        // Validate token contract
		try IJACKsPools(_token).getLpValue() returns (uint256) {
			// Token contract valid
		} catch {
			revert("Invalid token contract");
		}
        
        TOKEN = IJACKsPools(_token);
        owner = msg.sender;
		
		// Start from round 1 to avoid default 0 == 0 issue
		currentRound = 1;
    }
    
    /**
	 * @notice Get current distribution threshold based on LP value
	 */
	function getCurrentThreshold() public view returns (uint256) {
		uint256 lpValue = TOKEN.getLpValue();
		
		if (lpValue < STAGE_2_LP_THRESHOLD) {
			return STAGE_1_POOL_THRESHOLD;
		} else if (lpValue < STAGE_3_LP_THRESHOLD) {
			return STAGE_2_POOL_THRESHOLD;
		} else if (lpValue < STAGE_4_LP_THRESHOLD) {
			return STAGE_3_POOL_THRESHOLD;
		} else if (lpValue < STAGE_5_LP_THRESHOLD) {
			return STAGE_4_POOL_THRESHOLD;
		} else {
			return STAGE_5_POOL_THRESHOLD;
		}
	}
    
	/**
	 * @notice Get minimum buy for eligibility based on LP value
	 */
	function getMinBuyForEligibility() public view returns (uint256) {
		uint256 lpValue = TOKEN.getLpValue();
		
		if (lpValue < STAGE_2_LP_THRESHOLD) {
			return STAGE_1_MIN_BUY;
		} else if (lpValue < STAGE_3_LP_THRESHOLD) {
			return STAGE_2_MIN_BUY;
		} else if (lpValue < STAGE_4_LP_THRESHOLD) {
			return STAGE_3_MIN_BUY;
		} else if (lpValue < STAGE_5_LP_THRESHOLD) {
			return STAGE_4_MIN_BUY;
		} else {
			return STAGE_5_MIN_BUY;
		}
	}

	/**
	 * @notice Get minimum tokens for eligibility based on LP value
	 */
	function getMinEligibilityTokens() public view returns (uint256) {
		uint256 lpValue = TOKEN.getLpValue();
		
		if (lpValue < STAGE_2_LP_THRESHOLD) {
			return STAGE_1_MIN_TOKENS;
		} else if (lpValue < STAGE_3_LP_THRESHOLD) {
			return STAGE_2_MIN_TOKENS;
		} else if (lpValue < STAGE_4_LP_THRESHOLD) {
			return STAGE_3_MIN_TOKENS;
		} else if (lpValue < STAGE_5_LP_THRESHOLD) {
			return STAGE_4_MIN_TOKENS;
		} else {
			return STAGE_5_MIN_TOKENS;
		}
	}
	
	/**
	 * @notice Add eligible buyer to buffer system
	 */
	function addEligibleBuyer(address buyer, uint256 ethAmount) external onlyToken {
		require(buyer != address(0), "Zero buyer");
		
		// Check minimum buy requirement
		if (ethAmount < getMinBuyForEligibility()) {
			return; // Buy too small, silently skip
		}
		
		// Check minimum token balance requirement
		uint256 buyerBalance = TOKEN.balanceOf(buyer);
		if (buyerBalance < getMinEligibilityTokens()) {
			return; // Not enough tokens, silently skip
		}
		
		// ONE TICKET per round - check if already has ticket
		if (lastTicketRound[buyer] >= currentRound) {
			return; // Already has ticket this round
		}
		
		// Add to active buffer
		BufferSet storage activeBuffer = buffers[activeBufferNum];

		activeBuffer.entries[activeBuffer.index] = BuyEntry({
			buyer: buyer,
			amount: ethAmount,
			timestamp: block.timestamp
		});

		activeBuffer.index = (activeBuffer.index + 1) % BUFFER_CAPACITY;
		if (activeBuffer.size < BUFFER_CAPACITY) activeBuffer.size++;
		
		// Mark that buyer has ticket for this round
		lastTicketRound[buyer] = currentRound;
		
		// Mix user's transaction into entropy pool 
		roundEntropy[currentRound] = keccak256(abi.encodePacked(
			roundEntropy[currentRound],
			buyer,
			ethAmount,
			block.timestamp,
			block.number,
			tx.gasprice
		));
		
		emit BuyerAdded(buyer, ethAmount, currentRound);
	
		// Auto-reset snapshot if stuck for 7 days (safety mechanism)
		if (snapshotTaken && block.timestamp > snapshotTimestamp + 7 days) {
			snapshotTaken = false;
			emit SnapshotAutoResetTimeout(snapshotRound, snapshotTimestamp, block.timestamp);
			emit SnapshotReset(snapshotRound, "7 day timeout");
		}
		
		// Check if snapshot needed (auto-snapshot when threshold reached)
		uint256 pool = address(this).balance - _getTotalPendingClaims();
		if (pool >= getCurrentThreshold() && !snapshotTaken) {
			_takeSnapshot();
		}
	}
	
	/**
	 * @notice Take snapshot by swapping buffers (gas efficient)
	 */
	function _takeSnapshot() internal {
		snapshotTaken = true;
		snapshotTimestamp = block.timestamp;
		snapshotRound = currentRound;
		snapshotBlockNumber = block.number; // Save snapshot block
		snapshotRevealBlock = block.number + REVEAL_DELAY_BLOCKS; // delayed reveal for extra entropy
		snapshotThreshold = getCurrentThreshold();
		
		// Mark current buffer as snapshot
		snapshotBufferNum = activeBufferNum;
		uint256 activeSize = buffers[activeBufferNum].size;
		
		emit SnapshotTaken(block.timestamp, activeSize, currentRound);
		
		// Rotate to next buffer (0→1→2→3→4→5→6→7→0)
		activeBufferNum = (activeBufferNum + 1) & 7;  // & 7 = % 8 (gas efficient!)
		
		// Reset new active buffer
		buffers[activeBufferNum].size = 0;
		buffers[activeBufferNum].index = 0;
		
		// Increment round for next entries
		currentRound++;
		
		emit BufferSwapped(activeBufferNum, currentRound);
		emit RoundReady(address(this).balance - _getTotalPendingClaims(), activeSize, snapshotRound);
	}
	
	/**
	 * @notice Get valid entries from snapshot buffer (filter expired)
	 */
	function _getValidSnapshotEntries() internal view returns (BuyEntry[] memory) {
		// Get snapshot buffer
		BufferSet storage snapshotBuffer = buffers[snapshotBufferNum];
		uint256 snapshotSize = snapshotBuffer.size;
		
		// Prevent underflow if snapshot taken early after deploy
		uint256 cutoffTime = snapshotTimestamp > ENTRY_EXPIRY 
			? snapshotTimestamp - ENTRY_EXPIRY 
			: 0;
		
		// Calculate start position in circular buffer
		uint256 startPos = snapshotBuffer.size < BUFFER_CAPACITY 
			? 0 
			: (snapshotBuffer.index + BUFFER_CAPACITY - snapshotBuffer.size) % BUFFER_CAPACITY;
		
		uint256 validCount = 0;
		
		// Count valid entries (iterate correctly through circular buffer)
		for (uint256 i = 0; i < snapshotSize; i++) {
			uint256 pos = (startPos + i) % BUFFER_CAPACITY;  // CIRCULAR READ
			if (snapshotBuffer.entries[pos].timestamp >= cutoffTime) {
				validCount++;
			}
		}
		
		// Return empty array if no valid entries (instead of revert)
		if (validCount == 0) {
			return new BuyEntry[](0);
		}
		
		// Build valid entries array
		BuyEntry[] memory validEntries = new BuyEntry[](validCount);
		uint256 index = 0;
		
		for (uint256 i = 0; i < snapshotSize; i++) {
			uint256 pos = (startPos + i) % BUFFER_CAPACITY;  // CIRCULAR READ
			if (snapshotBuffer.entries[pos].timestamp >= cutoffTime) {
				validEntries[index] = snapshotBuffer.entries[pos];
				index++;
			}
		}
		
		return validEntries;
	}
	
   /**
	 * @notice Receive tax funds from token contract
	 */
	function onTaxReceived() external payable onlyToken {
		require(msg.value > 0, "No value");
		
		uint256 poolAfter = address(this).balance;
		emit Funded(msg.sender, msg.value, poolAfter);
		
		// Check if reward threshold reached and we have eligible buyers
		uint256 pool = poolAfter - _getTotalPendingClaims();
		uint256 activeSize = buffers[activeBufferNum].size;
		
		if (pool >= getCurrentThreshold() && activeSize > 0) {
			// Auto-snapshot if not already taken
			if (!snapshotTaken) {
				_takeSnapshot();
			}
		}
	}
       
    /**
	 * @notice Finalize round and select random recipient from snapshot
	 */
	function finalizeRound() external nonReentrant {
		require(snapshotTaken, "No snapshot taken");
		
		uint256 pool = address(this).balance - _getTotalPendingClaims();
		require(pool >= snapshotThreshold, "Threshold not met");
		
		// Prevent stale blockhash (blockhash only works for last 256 blocks)
		if (block.number > snapshotBlockNumber + 256) {
			snapshotTaken = false;
			emit RoundExpiredBlockhashStale(snapshotRound, snapshotBlockNumber, block.number);
			emit SnapshotReset(snapshotRound, "Snapshot expired - take new snapshot");
			return;
		}

		
		// Prevent rapid consecutive finalizations
		require(
			block.timestamp >= lastFinalizeTime + FINALIZE_COOLDOWN,
			"Cooldown active"
		);
		
		// Get valid entries from snapshot buffer
		BuyEntry[] memory validEntries = _getValidSnapshotEntries();
		
		// If no valid entries, reset snapshot and exit
		if (validEntries.length == 0) {
			snapshotTaken = false;
			emit SnapshotReset(snapshotRound, "No valid entries");
			return;
		}
		
		// Verify reveal block reached
		require(block.number >= snapshotRevealBlock, "Wait for reveal block");
				
		// Generate base random seed with multi-source entropy
		uint256 randomSeed = uint256(keccak256(abi.encodePacked(
			// PAST blocks (at snapshot time) - safe checks for underflow
			snapshotBlockNumber > 0 ? blockhash(snapshotBlockNumber - 1) : bytes32(0),
			snapshotBlockNumber > 2 ? blockhash(snapshotBlockNumber - 3) : bytes32(0),
			
			// FUTURE blocks (unknown at snapshot)
			blockhash(snapshotRevealBlock),
			block.number > 0 ? blockhash(block.number - 1) : bytes32(0),
			
			// Current state
			block.timestamp,
			block.prevrandao,
			block.number,
			
			// Round data
			snapshotRound,
			snapshotTimestamp,
			pool,
			
			// Community entropy (user contributions)
			roundEntropy[snapshotRound],
			
			// Transaction context
			msg.sender,
			tx.gasprice
		)));

		// CACHE MIN TOKENS (avoid repeated external call)
		uint256 minTokens = getMinEligibilityTokens();

		// CACHE BALANCES (avoid external calls in loops)
		uint256[] memory balances = new uint256[](validEntries.length);
		for (uint256 i = 0; i < validEntries.length; i++) {
			balances[i] = TOKEN.balanceOf(validEntries[i].buyer);
		}

		// TRY TO FIND ELIGIBLE WINNER (bounded retries)
		address recipient;
		bool found = false;
		uint256 maxAttempts = validEntries.length < 50 ? validEntries.length : 50;

		for (uint256 attempt = 0; attempt < maxAttempts && !found; attempt++) {
			// Re-hash seed with attempt counter
			uint256 attemptSeed = uint256(keccak256(abi.encodePacked(randomSeed, attempt)));
			uint256 selectedIndex = attemptSeed % validEntries.length;
			address candidate = validEntries[selectedIndex].buyer;
			
			// Check if eligible (using cached balance)
			if (balances[selectedIndex] >= minTokens) {
				recipient = candidate;
				found = true;
			}
		}

		// FALLBACK: Randomized scan for first eligible (using cached balances)
		if (!found) {
			uint256 fallbackStart = uint256(keccak256(abi.encodePacked(randomSeed, "fallback"))) % validEntries.length;
			for (uint256 i = 0; i < validEntries.length; i++) {
				uint256 idx = (fallbackStart + i) % validEntries.length;
				if (balances[idx] >= minTokens) {
					recipient = validEntries[idx].buyer;
					found = true;
					break;
				}
			}
		}

		// If STILL not found, round has NO eligible winners
		if (!found) {
			snapshotTaken = false;
			uint256 poolReturned = address(this).balance - _getTotalPendingClaims();
			emit RoundSkippedNoEligibleWinners(snapshotRound, validEntries.length, poolReturned);
			emit SnapshotReset(snapshotRound, "No eligible winners");
			return;
		}

		// NOW safe to reset snapshot (after guaranteed valid recipient)
		snapshotTaken = false;

		uint256 rewardAmount = pool; // 100% to winner
		
		// Record round info
		rounds[payoutRound] = RoundInfo({
			recipient: recipient,
			amount: rewardAmount,
			timestamp: block.timestamp,
			claimed: false
		});
		
		// Per-round tracking
		userRounds[recipient].push(payoutRound);
		recipientHistory[recipient] += rewardAmount;
		totalDistributed += rewardAmount;

		// Track unique recipients
		if (!hasReceivedBefore[recipient]) {
			uniqueRecipients.push(recipient);
			hasReceivedBefore[recipient] = true;
		}

		// Track largest reward
		if (rewardAmount > largestReward) {
			largestReward = rewardAmount;
		}
		
		// Reset for next round
		lastFinalizeTime = block.timestamp;
		uint256 currentRoundCompleted = payoutRound;
		payoutRound++;
		
		emit RewardDistributed(recipient, rewardAmount, currentRoundCompleted);
	}
    
	/**
     * @notice Get recent recipients (for website display)
     */
    function getRecentRecipients(uint256 count) external view returns (
        uint256[] memory roundIds,
        address[] memory recipients,
        uint256[] memory amounts,
        uint256[] memory timestamps,
        bool[] memory claimedStatus
    ) {
        uint256 totalRounds = payoutRound;
        if (totalRounds == 0) {
            return (
                new uint256[](0),
                new address[](0),
                new uint256[](0),
                new uint256[](0),
                new bool[](0)
            );
        }
        
        uint256 startRound = totalRounds > count ? totalRounds - count : 0;
        uint256 actualCount = totalRounds - startRound;
        
        roundIds = new uint256[](actualCount);
        recipients = new address[](actualCount);
        amounts = new uint256[](actualCount);
        timestamps = new uint256[](actualCount);
        claimedStatus = new bool[](actualCount);
        
        for (uint256 i = 0; i < actualCount; i++) {
            uint256 roundId = startRound + i;
            RoundInfo memory info = rounds[roundId];
            roundIds[i] = roundId;
            recipients[i] = info.recipient;
            amounts[i] = info.amount;
            timestamps[i] = info.timestamp;
            claimedStatus[i] = info.claimed;
        }
    }
    
    /**
     * @notice Get all rewards received by a specific user
     * @dev Uses userRounds index - O(wins) not O(all rounds)
     */
    function getUserRewards(address user) external view returns (
        uint256[] memory roundIds,
        uint256[] memory amounts,
        uint256[] memory timestamps,
        bool[] memory claimedStatus
    ) {
        uint256[] memory allRounds = userRounds[user];
        uint256 count = allRounds.length;

        if (count == 0) {
            return (
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new bool[](0)
            );
        }

        roundIds = new uint256[](count);
        amounts = new uint256[](count);
        timestamps = new uint256[](count);
        claimedStatus = new bool[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 rid = allRounds[i];
            roundIds[i] = rid;
            amounts[i] = rounds[rid].amount;
            timestamps[i] = rounds[rid].timestamp;
            claimedStatus[i] = rounds[rid].claimed;
        }
    }
        
    /**
     * @notice Get aggregate statistics
     */
    function getStatistics() external view returns (
		uint256 totalRounds,
		uint256 totalDistributedAmount,
		uint256 totalClaimedAmount,
		uint256 uniqueRecipientCount,
		uint256 largestRewardAmount,
		uint256 currentPool,
		uint256 currentThreshold,
		bool roundReady
	) {
		totalRounds = payoutRound;
		totalDistributedAmount = totalDistributed;
		totalClaimedAmount = totalClaimed;
		uniqueRecipientCount = uniqueRecipients.length;
		largestRewardAmount = largestReward;
		uint256 _bal = address(this).balance;
		uint256 _pending = _getTotalPendingClaims();
		currentPool = _bal > _pending ? _bal - _pending : 0;
		currentThreshold = getCurrentThreshold();
		roundReady = snapshotTaken;
	}
    	
	/**
	 * @notice Get entries from active buffer
	 */
	function getActiveBufferEntries(uint256 start, uint256 count) external view returns (
		address[] memory buyers,
		uint256[] memory amounts,
		uint256[] memory timestamps
	) {
		BufferSet storage activeBuffer = buffers[activeBufferNum];
		uint256 activeSize = activeBuffer.size;
		
		// Validate start position
		require(start < activeSize, "Start out of bounds");
		
		// Calculate end position (clamped to activeSize)
		uint256 end = start + count;
		if (end > activeSize) end = activeSize;
		
		uint256 resultCount = end - start;
		buyers = new address[](resultCount);
		amounts = new uint256[](resultCount);
		timestamps = new uint256[](resultCount);
		
		// Calculate circular start position (oldest entry)
		uint256 startPos = activeSize < BUFFER_CAPACITY 
			? 0 
			: (activeBuffer.index + BUFFER_CAPACITY - activeSize) % BUFFER_CAPACITY;
		
		// Read circularly
		for (uint256 i = 0; i < resultCount; i++) {
			uint256 pos = (startPos + start + i) % BUFFER_CAPACITY; // CIRCULAR!
			BuyEntry memory entry = activeBuffer.entries[pos];
			buyers[i] = entry.buyer;
			amounts[i] = entry.amount;
			timestamps[i] = entry.timestamp;
		}
	}
	
    /**
     * @notice Get list of unique recipient addresses
     */
    function getUniqueRecipients() external view returns (address[] memory) {
        return uniqueRecipients;
    }
    
    /**
	 * @notice Claim reward from a specific round
	 * @param roundId Round ID to claim
	 */
	function claimReward(uint256 roundId) external nonReentrant {
		require(roundId < payoutRound, "Invalid round");
		require(rounds[roundId].recipient == msg.sender, "Not your round");
		require(!rounds[roundId].claimed, "Already claimed");
		require(rounds[roundId].amount > 0, "No reward");
		require(
			block.timestamp <= rounds[roundId].timestamp + MAX_CLAIM_DELAY,
			"Claim deadline passed"
		);

		uint256 reward = rounds[roundId].amount;

		address payable recipient = payoutAddress[msg.sender] != address(0)
			? payoutAddress[msg.sender]
			: payable(msg.sender);

		// CEI: effects first
		rounds[roundId].claimed = true;
		totalClaimed += reward;

		(bool success,) = recipient.call{value: reward}("");
		require(success, "Transfer failed");

		emit RewardClaimed(msg.sender, recipient, roundId, reward);
	}

	/**
	 * @notice Claim rewards from multiple rounds in one tx
	 * @param roundIds Array of round IDs to claim (invalid/expired/others silently skipped)
	 */
	function claimMultipleRewards(uint256[] calldata roundIds) external nonReentrant {
		uint256 totalReward = 0;

		address payable recipient = payoutAddress[msg.sender] != address(0)
			? payoutAddress[msg.sender]
			: payable(msg.sender);

		for (uint256 i = 0; i < roundIds.length; i++) {
			uint256 roundId = roundIds[i];

			// Skip invalid round IDs silently
			if (roundId >= payoutRound) continue;

			if (
				rounds[roundId].recipient == msg.sender &&
				!rounds[roundId].claimed &&
				rounds[roundId].amount > 0 &&
				block.timestamp <= rounds[roundId].timestamp + MAX_CLAIM_DELAY
			) {
				uint256 reward = rounds[roundId].amount;
				rounds[roundId].claimed = true;
				totalClaimed += reward;
				totalReward += reward;

				emit RewardClaimed(msg.sender, recipient, roundId, reward);
			}
		}

		require(totalReward > 0, "No rewards to claim");

		(bool success,) = recipient.call{value: totalReward}("");
		require(success, "Transfer failed");
	}

	/**
	 * @notice Get claimable rounds for a user (non-expired, unclaimed only)
	 * @param user Address to check
	 */
	function getClaimableRounds(address user) external view returns (
		uint256[] memory roundIds,
		uint256[] memory amounts
	) {
		uint256[] memory allRounds = userRounds[user];
		uint256 count = 0;

		for (uint256 i = 0; i < allRounds.length; i++) {
			uint256 rid = allRounds[i];
			if (
				!rounds[rid].claimed &&
				rounds[rid].amount > 0 &&
				block.timestamp <= rounds[rid].timestamp + MAX_CLAIM_DELAY
			) {
				count++;
			}
		}

		roundIds = new uint256[](count);
		amounts = new uint256[](count);
		uint256 idx = 0;

		for (uint256 i = 0; i < allRounds.length; i++) {
			uint256 rid = allRounds[i];
			if (
				!rounds[rid].claimed &&
				rounds[rid].amount > 0 &&
				block.timestamp <= rounds[rid].timestamp + MAX_CLAIM_DELAY
			) {
				roundIds[idx] = rid;
				amounts[idx] = rounds[rid].amount;
				idx++;
			}
		}
	}

	/**
	 * @notice Get all round IDs won by a user (for frontend/debugging)
	 * @param user Address to check
	 */
	function getUserRoundIds(address user) external view returns (uint256[] memory) {
		return userRounds[user];
	}
    
    /**
     * @notice Get total pending claims
     */
    function _getTotalPendingClaims() private view returns (uint256) {
        return totalDistributed - totalClaimed;
    }
   
    /**
     * @notice Get potential round reward
     */
    function getRoundReward() external view returns (uint256) {
        uint256 rrPending = _getTotalPendingClaims();
        uint256 rrBal = address(this).balance;
        uint256 pool = rrBal > rrPending ? rrBal - rrPending : 0;
        if (pool >= getCurrentThreshold()) {
            return pool;
        }
        return 0;
    }
    
    /**
     * @notice Get round information
     */
    function getRoundInfo(uint256 roundId) external view returns (
        address recipient,
        uint256 amount,
        uint256 timestamp,
        bool claimed
    ) {
        RoundInfo memory info = rounds[roundId];
        return (info.recipient, info.amount, info.timestamp, info.claimed);
    }
    
	/**
	 * @notice Set custom payout address (for contract wallets)
	 * @param _payoutAddress Address to receive claim payouts
	 */
	function setPayoutAddress(address payable _payoutAddress) external {
		require(_payoutAddress != address(0), "Zero address");
		payoutAddress[msg.sender] = _payoutAddress;
		emit PayoutAddressSet(msg.sender, _payoutAddress);
	}

	/**
	 * @notice Clear payout address (revert to msg.sender)
	 */
	function clearPayoutAddress() external {
		delete payoutAddress[msg.sender];
		emit PayoutAddressSet(msg.sender, address(0));
	}
	
    /**
     * @notice Renounce ownership
     */
    function renounceOwnership() external onlyOwner {
        owner = address(0);
        emit OwnershipRenounced();
    }
      
	/**
	 * @notice Cleanup expired claims for a specific round
	 * @dev Expired unclaimed rewards are released back to the active pool.
	 *      Increasing totalClaimed reduces _getTotalPendingClaims() so this
	 *      ETH becomes reusable for future rounds without leaving the vault.
	 * @param roundId Round to cleanup
	 * @return recovered Amount of ETH freed (round amount if expired unclaimed, 0 otherwise)
	 */
	function cleanupExpiredClaimsForRound(uint256 roundId) public returns (uint256 recovered) {
		require(roundId < payoutRound, "Invalid round");

		RoundInfo storage info = rounds[roundId];

		// Skip if no amount, already claimed, or not yet expired
		if (info.amount == 0) return 0;
		if (info.claimed || block.timestamp <= info.timestamp + MAX_CLAIM_DELAY) {
			return 0;
		}

		// Mark as claimed and release ETH back to active pool
		info.claimed = true;
		totalClaimed += info.amount;

		emit ExpiredClaimCleaned(roundId, info.amount);
		return info.amount;
	}

	/**
	 * @notice Cleanup expired claims for a range of rounds (batched)
	 * @param startRound First round to cleanup (inclusive)
	 * @param endRound Last round to cleanup (inclusive)
	 * @return recovered Total amount of ETH freed
	 */
	function cleanupExpiredClaimsBatch(uint256 startRound, uint256 endRound) external returns (uint256 recovered) {
		require(startRound <= endRound, "Invalid range");
		require(endRound < payoutRound, "Invalid end round");

		for (uint256 i = startRound; i <= endRound; i++) {
			recovered += cleanupExpiredClaimsForRound(i);
		}
	}
	
	/**
	 * @notice Get expired rounds within a range (paginated)
	 * @dev getExpiredRounds() scans 0..payoutRound and becomes slow over time.
	 *      Use this for bounded, predictable gas in long-running protocols.
	 * @param fromRound Start round (inclusive)
	 * @param toRound End round (exclusive, auto-capped at payoutRound)
	 */
	function getExpiredRoundsInRange(
		uint256 fromRound,
		uint256 toRound
	) external view returns (uint256[] memory roundIds) {
		if (toRound > payoutRound) toRound = payoutRound;
		require(fromRound <= toRound, "Invalid range");

		uint256 count = 0;
		for (uint256 i = fromRound; i < toRound; i++) {
			if (
				!rounds[i].claimed &&
				rounds[i].amount > 0 &&
				block.timestamp > rounds[i].timestamp + MAX_CLAIM_DELAY
			) {
				count++;
			}
		}

		roundIds = new uint256[](count);
		uint256 idx = 0;

		for (uint256 i = fromRound; i < toRound; i++) {
			if (
				!rounds[i].claimed &&
				rounds[i].amount > 0 &&
				block.timestamp > rounds[i].timestamp + MAX_CLAIM_DELAY
			) {
				roundIds[idx] = i;
				idx++;
			}
		}

		return roundIds;
	}

	/**
	 * @notice Get complete buyer round state in single call
	 * @dev Batch info for dashboard/header display
	 */
	function getRoundState() external view returns (
		uint256, // currentRoundNum
		bool,    // isSnapshotTaken
		uint256, // snapshotRoundNum
		uint256, // activeBufferNum
		uint256, // snapshotBufferNum
		uint256, // snapshotTimestamp
		uint256, // snapshotBlockNumber
		uint256, // snapshotRevealBlock
		uint256, // availablePool
		uint256, // poolThreshold
		uint256, // minBuyRequired
		uint256, // minTokensRequired
		uint256  // activeEntries
	) {
		uint256 pending = _getTotalPendingClaims();
		uint256 bal = address(this).balance;
		
		return (
			currentRound,
			snapshotTaken,
			snapshotRound,
			activeBufferNum,
			snapshotTaken ? snapshotBufferNum : activeBufferNum,
			snapshotTimestamp,
			snapshotBlockNumber,
			snapshotRevealBlock,
			bal > pending ? bal - pending : 0,
			getCurrentThreshold(),
			getMinBuyForEligibility(),
			getMinEligibilityTokens(),
			buffers[activeBufferNum].size
		);
	}

	/**
	 * @notice Get user's ticket status for current round
	 */
	function getUserTicketStatus(address user) external view returns (
		bool hasTicketThisRound,
		uint256 lastRoundTicketed,
		bool isEligibleByTokens,
		bool canEnterIfBuysMin,
		uint256 userTokenBalance,
		uint256 minBuyRequired,
		uint256 minTokensRequired
	) {
		hasTicketThisRound = lastTicketRound[user] == currentRound;
		lastRoundTicketed = lastTicketRound[user];
		userTokenBalance = TOKEN.balanceOf(user);
		minBuyRequired = getMinBuyForEligibility();
		minTokensRequired = getMinEligibilityTokens();
		isEligibleByTokens = userTokenBalance >= minTokensRequired;
		canEnterIfBuysMin = isEligibleByTokens && !hasTicketThisRound;
		
		return (
			hasTicketThisRound,
			lastRoundTicketed,
			isEligibleByTokens,
			canEnterIfBuysMin,
			userTokenBalance,
			minBuyRequired,
			minTokensRequired
		);
	}

	/**
	 * @notice Get finalization readiness and countdown timers
	 */
	function getFinalizeTimers() external view returns (
		bool canFinalizeNow,
		bool canFinalizeByBlock,
		uint256 blocksUntilReveal,
		bool canFinalizeByCooldown,
		uint256 secondsUntilCooldown,
		uint256 snapshotAge,
		bool willAutoReset,
		uint256 secondsUntilAutoReset,
		bool blockhashUnavailable
	) {
		if (!snapshotTaken) {
			return (false, false, 0, false, 0, 0, false, 0, false);
		}
		
		uint256 pending = _getTotalPendingClaims();
		uint256 bal = address(this).balance;
		uint256 pool = bal > pending ? bal - pending : 0;
		
		blockhashUnavailable = block.number > snapshotBlockNumber + 256;
		canFinalizeByBlock = block.number >= snapshotRevealBlock;
		canFinalizeByCooldown = block.timestamp >= lastFinalizeTime + FINALIZE_COOLDOWN;
		
		canFinalizeNow = snapshotTaken 
			&& pool >= snapshotThreshold
			&& canFinalizeByBlock
			&& canFinalizeByCooldown
			&& !blockhashUnavailable;
		
		blocksUntilReveal = canFinalizeByBlock ? 0 : (snapshotRevealBlock - block.number);
		secondsUntilCooldown = canFinalizeByCooldown ? 0 : (lastFinalizeTime + FINALIZE_COOLDOWN - block.timestamp);
		
		snapshotAge = block.timestamp > snapshotTimestamp ? block.timestamp - snapshotTimestamp : 0;
		willAutoReset = snapshotAge > 7 days;
		secondsUntilAutoReset = willAutoReset ? 0 : (7 days - snapshotAge);
		
		return (
			canFinalizeNow,
			canFinalizeByBlock,
			blocksUntilReveal,
			canFinalizeByCooldown,
			secondsUntilCooldown,
			snapshotAge,
			willAutoReset,
			secondsUntilAutoReset,
			blockhashUnavailable
		);
	}

	/**
	 * @notice Count valid (non-expired) entries in snapshot buffer
	 */
	function getValidSnapshotEntriesCount() external view returns (uint256) {
		if (!snapshotTaken) {
			return 0;
		}
		
		BufferSet storage buffer = buffers[snapshotBufferNum];
		uint256 size = buffer.size;
		
		uint256 cutoffTime = snapshotTimestamp > ENTRY_EXPIRY 
			? snapshotTimestamp - ENTRY_EXPIRY 
			: 0;
		
		uint256 startPos = size < BUFFER_CAPACITY 
			? 0 
			: (buffer.index + BUFFER_CAPACITY - size) % BUFFER_CAPACITY;
		
		uint256 validCount = 0;
		
		for (uint256 i = 0; i < size; i++) {
			uint256 pos = (startPos + i) % BUFFER_CAPACITY;
			if (buffer.entries[pos].timestamp >= cutoffTime) {
				validCount++;
			}
		}
		
		return validCount;
	}
	
    /**
     * @notice Prevent direct funding
     */
    receive() external payable {
        revert("Direct funding disabled");
    }
}
