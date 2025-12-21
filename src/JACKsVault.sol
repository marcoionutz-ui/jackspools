// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JACKs Reward Vault - Buyer Round Distribution
 * @notice Core vault of the JACKs Pots ecosystem, holding and distributing
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

	// 8-buffer system for 4,096 address capacity
	struct BufferSet {
		BuyEntry[512] entries;  // 512 slots per buffer
		uint256 size;           // Current entries in this buffer
		uint256 index;          // Next write position (circular)
	}

	BufferSet[8] public buffers;  // 8 buffere × 512 = 4,096 total

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
	mapping(uint256 => bytes32) public roundEntropy; // Community entropy per round

	// Constants for buffer system
	uint256 public constant BUFFER_CAPACITY = 512;
	uint256 public constant BUFFER_COUNT = 8;
	uint256 public constant TOTAL_CAPACITY = 4096;  // 8 × 512
	uint256 public constant ENTRY_EXPIRY = 2 hours;
    
    // Configuration
	uint256 public constant MAX_CLAIM_DELAY = 30 days; // Safety: auto-release after 30 days
	uint256 public constant FINALIZE_COOLDOWN = 3 minutes;
	
	// Stage LP thresholds
	uint256 private constant STAGE_2_LP_THRESHOLD = 2 ether;
	uint256 private constant STAGE_3_LP_THRESHOLD = 5 ether;
	uint256 private constant STAGE_4_LP_THRESHOLD = 10 ether;
	uint256 private constant STAGE_5_LP_THRESHOLD = 20 ether;

	// Stage 1: Pot thresholds (LP < 2 ETH)
	uint256 private constant STAGE_1_POT_THRESHOLD = 0.014 ether;   // $50 @ $3500/ETH
	uint256 private constant STAGE_1_MIN_BUY = 0.00043 ether;       // $1.50 @ $3500/ETH
	uint256 private constant STAGE_1_MIN_TOKENS = 1_000_000 * 10**18; // 1M tokens

	// Stage 2: Pot thresholds (LP 2-5 ETH)
	uint256 private constant STAGE_2_POT_THRESHOLD = 0.057 ether;   // $200 @ $3500/ETH
	uint256 private constant STAGE_2_MIN_BUY = 0.00057 ether;       // $2 @ $3500/ETH
	uint256 private constant STAGE_2_MIN_TOKENS = 250_000 * 10**18; // 250k tokens

	// Stage 3: Pot thresholds (LP 5-10 ETH)
	uint256 private constant STAGE_3_POT_THRESHOLD = 0.143 ether;   // $500 @ $3500/ETH
	uint256 private constant STAGE_3_MIN_BUY = 0.00071 ether;       // $2.50 @ $3500/ETH
	uint256 private constant STAGE_3_MIN_TOKENS = 100_000 * 10**18; // 100k tokens

	// Stage 4: Pot thresholds (LP 10-20 ETH)
	uint256 private constant STAGE_4_POT_THRESHOLD = 0.286 ether;   // $1,000 @ $3500/ETH
	uint256 private constant STAGE_4_MIN_BUY = 0.00086 ether;       // $3 @ $3500/ETH
	uint256 private constant STAGE_4_MIN_TOKENS = 50_000 * 10**18;  // 50k tokens

	// Stage 5: Pot thresholds (LP > 20 ETH)
	uint256 private constant STAGE_5_POT_THRESHOLD = 0.714 ether;   // $2,500 @ $3500/ETH
	uint256 private constant STAGE_5_MIN_BUY = 0.001 ether;         // $3.50 @ $3500/ETH
	uint256 private constant STAGE_5_MIN_TOKENS = 5 * 10**18;       // 5 tokens
    
    // State
    uint256 public round;
    uint256 public totalDistributed;
    uint256 public totalClaimed;
	uint256 public lastFinalizeTime;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public recipientHistory;
    mapping(uint256 => RoundInfo) public rounds;
	
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
    bool public emergencyPause;
    
    // Events
    event Funded(address indexed from, uint256 amount, uint256 potAfter);
	event BuyerAdded(address indexed buyer, uint256 amount, uint256 round);
	event SnapshotTaken(uint256 timestamp, uint256 entries, uint256 round);
	event BufferSwapped(uint256 newActiveBufferNum, uint256 round);
    event RoundReady(uint256 poolBalance, uint256 eligibleBuyers, uint256 round);
    event RewardDistributed(address indexed recipient, uint256 amount, uint256 round);
    event Claimed(address indexed recipient, uint256 amount);
	event SnapshotReset(uint256 indexed round, string reason);
    event EmergencyPauseSet(bool paused);
    event OwnershipRenounced();
    
    modifier onlyToken() {
        require(msg.sender == address(TOKEN), "Only token");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
         
    modifier notPaused() {
        require(!emergencyPause, "Paused");
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
			return STAGE_1_POT_THRESHOLD;
		} else if (lpValue < STAGE_3_LP_THRESHOLD) {
			return STAGE_2_POT_THRESHOLD;
		} else if (lpValue < STAGE_4_LP_THRESHOLD) {
			return STAGE_3_POT_THRESHOLD;
		} else if (lpValue < STAGE_5_LP_THRESHOLD) {
			return STAGE_4_POT_THRESHOLD;
		} else {
			return STAGE_5_POT_THRESHOLD;
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
	function addEligibleBuyer(address buyer, uint256 ethAmount) external onlyToken notPaused {
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
			emit SnapshotReset(snapshotRound, "7 day timeout");
		}
		
		// Check if snapshot needed (auto-snapshot when threshold reached)
		uint256 pot = address(this).balance - _getTotalPendingClaims();
		if (pot >= getCurrentThreshold() && !snapshotTaken) {
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
		snapshotBlockNumber = block.number;           // NEW: Save snapshot block
		snapshotRevealBlock = block.number + 5;       // NEW: +5 blocks (~15s delay)
		
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
	function onTaxReceived() external payable onlyToken notPaused {
		require(msg.value > 0, "No value");
		
		uint256 potAfter = address(this).balance;
		emit Funded(msg.sender, msg.value, potAfter);
		
		// Check if reward threshold reached and we have eligible buyers
		uint256 pot = potAfter - _getTotalPendingClaims();
		uint256 activeSize = buffers[activeBufferNum].size;
		
		if (pot >= getCurrentThreshold() && activeSize > 0) {
			emit RoundReady(pot, activeSize, currentRound);
		
			// Auto-snapshot if not already taken
			if (!snapshotTaken) {
				_takeSnapshot();
			}
		}
	}
       
    /**
	 * @notice Finalize round and select random recipient from snapshot
	 */
	function finalizeRound() external nonReentrant notPaused {
		require(snapshotTaken, "No snapshot taken");
		
		uint256 pot = address(this).balance - _getTotalPendingClaims();
		require(pot >= getCurrentThreshold(), "Threshold not met");
		
		// Prevent stale blockhash (blockhash only works for last 256 blocks)
		if (block.number > snapshotBlockNumber + 256) {
			snapshotTaken = false;
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
			pot,
			
			// Community entropy (user contributions)
			roundEntropy[snapshotRound],
			
			// Transaction context
			msg.sender,
			tx.gasprice
		)));

		// TRY TO FIND ELIGIBLE WINNER (bounded retries)
		address recipient;
		bool found = false;
		uint256 maxAttempts = validEntries.length < 20 ? validEntries.length : 20;

		for (uint256 attempt = 0; attempt < maxAttempts && !found; attempt++) {
			// Re-hash seed with attempt counter
			uint256 attemptSeed = uint256(keccak256(abi.encodePacked(randomSeed, attempt)));
			uint256 selectedIndex = attemptSeed % validEntries.length;
			address candidate = validEntries[selectedIndex].buyer;
			
			// Check if eligible
			if (TOKEN.balanceOf(candidate) >= getMinEligibilityTokens()) {
				recipient = candidate;
				found = true;
			}
		}

		// FALLBACK: Linear scan for first eligible (if random failed)
		if (!found) {
			for (uint256 i = 0; i < validEntries.length; i++) {
				if (TOKEN.balanceOf(validEntries[i].buyer) >= getMinEligibilityTokens()) {
					recipient = validEntries[i].buyer;
					found = true;
					break;
				}
			}
		}

		// If STILL not found, round has NO eligible winners
		if (!found) {
			snapshotTaken = false;
			emit SnapshotReset(snapshotRound, "No eligible winners");
			return;
		}

		// NOW safe to reset snapshot (after guaranteed valid recipient)
		snapshotTaken = false;

		uint256 rewardAmount = pot; // 100% to winner
		
		// Record round info
		rounds[round] = RoundInfo({
			recipient: recipient,
			amount: rewardAmount,
			timestamp: block.timestamp,
			claimed: false
		});
		
		// Add to claimable
		claimable[recipient] += rewardAmount;
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
		uint256 currentRoundCompleted = round;
		round++;
		
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
        uint256 totalRounds = round;
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
     */
    function getUserRewards(address user) external view returns (
        uint256[] memory roundIds,
        uint256[] memory amounts,
        uint256[] memory timestamps,
        bool[] memory claimedStatus
    ) {
        uint256 count = 0;
        for (uint256 i = 0; i < round; i++) {
            if (rounds[i].recipient == user && rounds[i].amount > 0) {
                count++;
            }
        }
        
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
        
        uint256 idx = 0;
        for (uint256 i = 0; i < round; i++) {
            if (rounds[i].recipient == user && rounds[i].amount > 0) {
                roundIds[idx] = i;
                amounts[idx] = rounds[i].amount;
                timestamps[idx] = rounds[i].timestamp;
                claimedStatus[idx] = rounds[i].claimed;
                idx++;
            }
        }
    }
    
    /**
     * @notice Get all unclaimed rewards
     */
    function getUnclaimedRewards() external view returns (
        uint256[] memory roundIds,
        address[] memory recipients,
        uint256[] memory amounts,
        uint256[] memory timestamps,
        uint256[] memory daysRemaining
    ) {
        uint256 unclaimedCount = 0;
        for (uint256 i = 0; i < round; i++) {
            if (!rounds[i].claimed && rounds[i].amount > 0) {
                unclaimedCount++;
            }
        }
        
        if (unclaimedCount == 0) {
            return (
                new uint256[](0),
                new address[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0)
            );
        }
        
        roundIds = new uint256[](unclaimedCount);
        recipients = new address[](unclaimedCount);
        amounts = new uint256[](unclaimedCount);
        timestamps = new uint256[](unclaimedCount);
        daysRemaining = new uint256[](unclaimedCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < round; i++) {
            if (!rounds[i].claimed && rounds[i].amount > 0) {
                roundIds[index] = i;
                recipients[index] = rounds[i].recipient;
                amounts[index] = rounds[i].amount;
                timestamps[index] = rounds[i].timestamp;
                
                uint256 deadline = rounds[i].timestamp + MAX_CLAIM_DELAY;
                if (block.timestamp < deadline) {
                    daysRemaining[index] = (deadline - block.timestamp) / 1 days;
                } else {
                    daysRemaining[index] = 0;
                }
                
                index++;
            }
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
		totalRounds = round;
		totalDistributedAmount = totalDistributed;
		totalClaimedAmount = totalClaimed;
		uniqueRecipientCount = uniqueRecipients.length;
		largestRewardAmount = largestReward;
		currentPool = address(this).balance - _getTotalPendingClaims();
		currentThreshold = getCurrentThreshold();
		roundReady = snapshotTaken;
	}
    
	/**
	 * @notice Get current active buffer info
	 */
	function getActiveBufferInfo() external view returns (
		uint256 size,
		uint256 capacity,
		uint256 bufferNum
	) {
		size = buffers[activeBufferNum].size;
		capacity = BUFFER_CAPACITY;
		bufferNum = activeBufferNum;
	}

	/**
	 * @notice Get snapshot buffer info
	 */
	function getSnapshotBufferInfo() external view returns (
		uint256 size,
		bool taken,
		uint256 timestamp,
		uint256 roundNumber,
		uint256 bufferNum
	) {
		size = buffers[snapshotBufferNum].size;
		taken = snapshotTaken;
		timestamp = snapshotTimestamp;
		roundNumber = snapshotRound;
		bufferNum = snapshotBufferNum;
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
		
		uint256 end = start + count;
		if (end > activeSize) end = activeSize;
		
		uint256 resultCount = end - start;
		buyers = new address[](resultCount);
		amounts = new uint256[](resultCount);
		timestamps = new uint256[](resultCount);
		
		for (uint256 i = 0; i < resultCount; i++) {
			BuyEntry memory entry = activeBuffer.entries[start + i];
			buyers[i] = entry.buyer;
			amounts[i] = entry.amount;
			timestamps[i] = entry.timestamp;
		}
	}
	
	/**
	 * @notice Get total active entries across all active buffers
	 */
	function getTotalActiveEntries() external view returns (uint256) {
		return buffers[activeBufferNum].size;
	}

	/**
	 * @notice Get all buffer statuses (for monitoring)
	 */
	function getAllBufferStatuses() external view returns (
		uint256[8] memory sizes,
		uint256[8] memory indices
	) {
		for (uint256 i = 0; i < BUFFER_COUNT; i++) {
			sizes[i] = buffers[i].size;
			indices[i] = buffers[i].index;
		}
	}
	
    /**
     * @notice Get list of unique recipient addresses
     */
    function getUniqueRecipients() external view returns (address[] memory) {
        return uniqueRecipients;
    }
    
    /**
     * @notice Get top N recipients by total amount received
     */
    function getTopRecipients(uint256 count) external view returns (
        address[] memory topRecipients,
        uint256[] memory topAmounts
    ) {
        uint256 totalUnique = uniqueRecipients.length;
        if (totalUnique == 0) {
            return (new address[](0), new uint256[](0));
        }
        
        uint256 resultCount = count > totalUnique ? totalUnique : count;
        
        address[] memory allRecipients = new address[](totalUnique);
        uint256[] memory allAmounts = new uint256[](totalUnique);
        
        for (uint256 i = 0; i < totalUnique; i++) {
            allRecipients[i] = uniqueRecipients[i];
            allAmounts[i] = recipientHistory[uniqueRecipients[i]];
        }
        
        // Simple bubble sort for small datasets
        for (uint256 i = 0; i < totalUnique; i++) {
            for (uint256 j = i + 1; j < totalUnique; j++) {
                if (allAmounts[j] > allAmounts[i]) {
                    uint256 tempAmount = allAmounts[i];
                    allAmounts[i] = allAmounts[j];
                    allAmounts[j] = tempAmount;
                    
                    address tempAddress = allRecipients[i];
                    allRecipients[i] = allRecipients[j];
                    allRecipients[j] = tempAddress;
                }
            }
        }
        
        topRecipients = new address[](resultCount);
        topAmounts = new uint256[](resultCount);
        
        for (uint256 i = 0; i < resultCount; i++) {
            topRecipients[i] = allRecipients[i];
            topAmounts[i] = allAmounts[i];
        }
    }
	
    /**
     * @notice Claim reward winnings
     */
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "Nothing to claim");
        
        // Reset first (prevent reentrancy)
        claimable[msg.sender] = 0;
        totalClaimed += amount;
                
        // Transfer prize
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
        
        emit Claimed(msg.sender, amount);
    }
    
    /**
     * @notice Get total pending claims
     */
    function _getTotalPendingClaims() private view returns (uint256) {
        return totalDistributed - totalClaimed;
    }
    
    /**
     * @notice Get current pool size (minus pending claims)
     */
    function getPoolSize() external view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 pending = _getTotalPendingClaims();
        return balance > pending ? balance - pending : 0;
    }
    
    /**
     * @notice Check if round is ready to be finalized
     */
    function isRoundReady() external view returns (bool) {
		return snapshotTaken;
	}
    
    /**
     * @notice Get potential round reward
     */
    function getRoundReward() external view returns (uint256) {
        uint256 pot = address(this).balance - _getTotalPendingClaims();
        if (pot >= getCurrentThreshold()) {
            return pot;
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
    
    // Owner functions
    
    /**
     * @notice Emergency pause (owner only)
     */
    function setEmergencyPause(bool _pause) external onlyOwner {
        emergencyPause = _pause;
        emit EmergencyPauseSet(_pause);
    }
    
    /**
     * @notice Renounce ownership
     */
    function renounceOwnership() external onlyOwner {
        owner = address(0);
        emit OwnershipRenounced();
    }
      
	/**
	 * @notice Emergency claim for stuck funds after 30 days (safety mechanism)
	 * @dev Gas-limited: only checks last 100 rounds to prevent out-of-gas
	 */
	function emergencyClaim(address recipient) external nonReentrant {
		require(claimable[recipient] > 0, "No claim");
		
		// Limit to last 100 rounds to prevent gas issues
		uint256 startRound = round > 100 ? round - 100 : 0;
		
		// Calculate and mark expired unclaimed rounds for this recipient
		uint256 expiredAmount = 0;
		for (uint256 i = startRound; i < round; i++) {
			if (rounds[i].recipient == recipient && 
				!rounds[i].claimed && 
				block.timestamp > rounds[i].timestamp + MAX_CLAIM_DELAY) {
				expiredAmount += rounds[i].amount;
				rounds[i].claimed = true;
			}
		}
		
		require(expiredAmount > 0, "No emergency claim");
		
		// Only pay expired amount, not entire claimable
		claimable[recipient] -= expiredAmount;
		totalClaimed += expiredAmount;
		
		(bool success,) = recipient.call{value: expiredAmount}("");
		require(success, "Transfer failed");
		
		emit Claimed(recipient, expiredAmount);
	}
	
	/**
	 * @notice Cleanup expired claims for a specific round (gas-efficient)
	 * @param roundId Round to cleanup
	 * @return recovered Amount of ETH freed
	 */
	function cleanupExpiredClaimsForRound(uint256 roundId) public returns (uint256 recovered) {
		require(roundId < round, "Invalid round");
		
		RoundInfo storage info = rounds[roundId];
		
		// Skip if already claimed or not expired
		if (info.claimed || block.timestamp <= info.timestamp + MAX_CLAIM_DELAY) {
			return 0;
		}
		
		address recipient = info.recipient;
		
		// If this round's recipient has any unclaimed amount
		if (claimable[recipient] > 0) {
			uint256 amountToRecover = claimable[recipient] >= info.amount 
				? info.amount 
				: claimable[recipient];
			
			// Mark as claimed and update accounting
			info.claimed = true;
			claimable[recipient] -= amountToRecover;
			totalClaimed += amountToRecover;
			recovered = amountToRecover;
		}
		
		return recovered;
	}

	/**
	 * @notice Cleanup expired claims for multiple rounds (batched)
	 * @param startRound First round to cleanup (inclusive)
	 * @param endRound Last round to cleanup (inclusive)
	 * @return recovered Total amount of ETH freed
	 */
	function cleanupExpiredClaimsBatch(uint256 startRound, uint256 endRound) external returns (uint256 recovered) {
		require(startRound <= endRound, "Invalid range");
		require(endRound < round, "Invalid end round");
		
		recovered = 0;
		
		for (uint256 i = startRound; i <= endRound; i++) {
			recovered += cleanupExpiredClaimsForRound(i);
		}
		
		return recovered;
	}

	/**
	 * @notice Cleanup all expired claims (backwards compatible)
	 * @dev Gas-optimized: only checks last 100 rounds max to prevent out-of-gas
	 * @return recovered Amount of ETH freed
	 */
	function cleanupExpiredClaims() external returns (uint256 recovered) {
		recovered = 0;
		
		// Limit to prevent gas issues
		uint256 startRound = round > 100 ? round - 100 : 0;
		
		for (uint256 i = startRound; i < round; i++) {
			recovered += cleanupExpiredClaimsForRound(i);
		}
		
		return recovered;
	}

	/**
	 * @notice Get list of rounds that need cleanup
	 * @return roundIds Array of round IDs with expired unclaimed rewards
	 */
	function getExpiredRounds() external view returns (uint256[] memory roundIds) {
		uint256 count = 0;
		
		for (uint256 i = 0; i < round; i++) {
			if (!rounds[i].claimed && 
				rounds[i].amount > 0 &&
				block.timestamp > rounds[i].timestamp + MAX_CLAIM_DELAY) {
				count++;
			}
		}
		
		roundIds = new uint256[](count);
		uint256 index = 0;
		
		for (uint256 i = 0; i < round; i++) {
			if (!rounds[i].claimed && 
				rounds[i].amount > 0 &&
				block.timestamp > rounds[i].timestamp + MAX_CLAIM_DELAY) {
				roundIds[index] = i;
				index++;
			}
		}
		
		return roundIds;
	}
	
    /**
     * @notice Prevent direct funding
     */
    receive() external payable {
        revert("Direct funding disabled");
    }
}
