// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JackpotVault - Buyer Reward Vault (Production Ready)
 * @notice Core vault of the JackpotToken ecosystem, holding and distributing
 *         community rewards using a secure pull-payment system.
 * @notice The term "Jackpot" does not refer to gambling or betting.
 *         It represents an autonomous reward mechanism that randomly selects
 *         eligible participants and pays out 100% of the pot.
 * @dev Features adaptive thresholds based on total LP value and ensures
 *      full payout to the winner without external control or intervention.
 */

interface IJackpotToken {
    function getLPValue() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract JackpotVault is ReentrancyGuard {
    IJackpotToken public immutable token;
	
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
    uint256 public constant SMALL_THRESHOLD = 0.25 ether; // 0.25 BNB when LP < 10 BNB
    uint256 public constant LARGE_THRESHOLD = 5 ether; // 5 BNB when LP >= 10 BNB
    uint256 public constant LP_THRESHOLD = 10 ether; // 10 BNB LP value threshold
    uint256 public constant MAX_CLAIM_DELAY = 30 days; // Safety: auto-release after 30 days
	uint256 public constant FINALIZE_COOLDOWN = 1 minutes;
    
    // State
    uint256 public round;
    uint256 public totalWon;
    uint256 public totalClaimed;
	uint256 public lastFinalizeTime;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public winnerHistory;
    mapping(uint256 => RoundInfo) public rounds;
	
	// Winner tracking (for statistics)
	address[] private uniqueWinners;
	mapping(address => bool) private hasWonBefore;
	uint256 public largestJackpot;
    
    struct RoundInfo {
        address winner;
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
    event JackpotArmed(uint256 pot, uint256 eligibleBuyers, uint256 round);
    event JackpotWon(address indexed winner, uint256 amount, uint256 round);
    event Claimed(address indexed winner, uint256 amount);
    event EmergencyPauseSet(bool paused);
    event OwnershipRenounced();
    
    modifier onlyToken() {
        require(msg.sender == address(token), "Only token");
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
		try IJackpotToken(_token).getLPValue() returns (uint256) {
			// Token contract valid
		} catch {
			revert("Invalid token contract");
		}
        
        token = IJackpotToken(_token);
        owner = msg.sender;
		
		// Start from round 1 to avoid default 0 == 0 issue
		currentRound = 1;
    }
    
    /**
     * @notice Get current jackpot threshold based on LP value
     */
    function getCurrentThreshold() public view returns (uint256) {
		uint256 lpValue = token.getLPValue();
		
		if (lpValue < 10 ether) {
			return 0.0833 ether; // Stage 1: $50 @ $600/BNB
		} else if (lpValue < 25 ether) {
			return 0.333 ether; // Stage 2: $200 @ $600/BNB
		} else if (lpValue < 50 ether) {
			return 0.833 ether; // Stage 3: $500 @ $600/BNB
		} else if (lpValue < 100 ether) {
			return 1.667 ether; // Stage 4: $1,000 @ $600/BNB
		} else {
			return 4.167 ether; // Stage 5: $2,500 @ $600/BNB
		}
	}
    
	/**
	 * @notice Get minimum buy for eligibility based on LP value
	 */
	function getMinBuyForEligibility() public view returns (uint256) {
		uint256 lpValue = token.getLPValue();
		
		if (lpValue < 10 ether) {
			return 0.0025 ether; // Stage 1: $1.50 @ $600/BNB when LP < 10 BNB
		} else if (lpValue < 25 ether) {
			return 0.00333 ether; // Stage 2: $2 @ $600/BNB when LP 10-25 BNB
		} else if (lpValue < 50 ether) {
			return 0.00417 ether; // Stage 3: $2.50 @ $600/BNB when LP 25-50 BNB
		} else if (lpValue < 100 ether) {
			return 0.005 ether; // Stage 4: $3 @ $600/BNB when LP 50-100 BNB
		} else {
			return 0.00583 ether; // Stage 5: $3.50 @ $600/BNB when LP > 100 BNB
		}
	}

	/**
	 * @notice Get minimum tokens for eligibility based on LP value
	 */
	function getMinEligibilityTokens() public view returns (uint256) {
		uint256 lpValue = token.getLPValue();
		
		if (lpValue < 10 ether) {
			return 1_000_000 * 10**18; // Stage 1: 1M tokens when LP < 10 BNB
		} else if (lpValue < 25 ether) {
			return 250_000 * 10**18; // Stage 2: 250k tokens when LP 10-25 BNB
		} else if (lpValue < 50 ether) {
			return 100_000 * 10**18; // Stage 3: 100k tokens when LP 25-50 BNB
		} else if (lpValue < 100 ether) {
			return 50_000 * 10**18; // Stage 4: 50k tokens when LP 50-100 BNB
		} else {
			return 5 * 10**18; // Stage 5: doar 5 tokens when LP > 100 BNB (tokens very expensive)
		}
	}
	
	/**
	 * @notice Add eligible buyer to buffer system
	 */
	function addEligibleBuyer(address buyer, uint256 bnbAmount) external onlyToken notPaused {
		require(buyer != address(0), "Zero buyer");
		
		// Check minimum buy requirement
		if (bnbAmount < getMinBuyForEligibility()) {
			return; // Buy too small, silently skip
		}
		
		// Check minimum token balance requirement
		uint256 buyerBalance = token.balanceOf(buyer);
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
			amount: bnbAmount,
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
			bnbAmount,
			block.timestamp,
			block.number,
			tx.gasprice
		));
		
		emit BuyerAdded(buyer, bnbAmount, currentRound);
		
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
		emit JackpotArmed(address(this).balance - _getTotalPendingClaims(), activeSize, snapshotRound);
	}
	
	/**
	 * @notice Get valid entries from snapshot buffer (filter expired)
	 */
	function _getValidSnapshotEntries() internal view returns (BuyEntry[] memory) {
		// Get snapshot buffer
		BufferSet storage snapshotBuffer = buffers[snapshotBufferNum];
		uint256 snapshotSize = snapshotBuffer.size;
		
		uint256 cutoffTime = snapshotTimestamp - ENTRY_EXPIRY;
		uint256 validCount = 0;
		
		// Count valid entries (not expired)
		for (uint256 i = 0; i < snapshotSize; i++) {
			if (snapshotBuffer.entries[i].timestamp >= cutoffTime) {
				validCount++;
			}
		}
		
		require(validCount > 0, "No valid entries");
		
		// Build valid entries array
		BuyEntry[] memory validEntries = new BuyEntry[](validCount);
		uint256 index = 0;
		
		for (uint256 i = 0; i < snapshotSize; i++) {
			if (snapshotBuffer.entries[i].timestamp >= cutoffTime) {
				validEntries[index] = snapshotBuffer.entries[i];
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
		
		// Check if jackpot threshold reached and we have eligible buyers
		uint256 pot = potAfter - _getTotalPendingClaims();
		uint256 activeSize = buffers[activeBufferNum].size;
		
		if (pot >= getCurrentThreshold() && activeSize > 0) {
			emit JackpotArmed(pot, activeSize, currentRound);
		}
	}
       
    /**
	 * @notice Finalize round and select random winner from snapshot
	 */
	function finalizeRound() external nonReentrant notPaused {
		require(snapshotTaken, "No snapshot taken");
		
		// Reset snapshot flag immediately to prevent double finalization
		snapshotTaken = false;
		
		uint256 pot = address(this).balance - _getTotalPendingClaims();
		require(pot >= getCurrentThreshold(), "Threshold not met");
		
		// Prevent rapid consecutive finalizations
		require(
			block.timestamp >= lastFinalizeTime + FINALIZE_COOLDOWN,
			"Cooldown active"
		);
		
		// Get valid entries from snapshot buffer
		BuyEntry[] memory validEntries = _getValidSnapshotEntries();
		
		// Verify reveal block reached
		require(block.number >= snapshotRevealBlock, "Wait for reveal block");

		// Generate random winner with multi-source entropy
		uint256 randomSeed = uint256(keccak256(abi.encodePacked(
			// PAST blocks (at snapshot time)
			blockhash(snapshotBlockNumber - 1),
			blockhash(snapshotBlockNumber - 3),
			
			// FUTURE blocks (unknown at snapshot)
			blockhash(snapshotRevealBlock),
			blockhash(block.number - 1),
			
			// Current state
			block.timestamp,
			block.difficulty,
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
		
		uint256 winnerIndex = randomSeed % validEntries.length;
		address winner = validEntries[winnerIndex].buyer;
		
		// Verify winner still eligible
		require(token.balanceOf(winner) >= getMinEligibilityTokens(), "Winner not eligible");
		
		uint256 winAmount = pot; // 100% to winner
		
		// Record round info
		rounds[round] = RoundInfo({
			winner: winner,
			amount: winAmount,
			timestamp: block.timestamp,
			claimed: false
		});
		
		// Add to claimable
		claimable[winner] += winAmount;
		winnerHistory[winner] += winAmount;
		totalWon += winAmount;
		
		// Track unique winners
		if (!hasWonBefore[winner]) {
			uniqueWinners.push(winner);
			hasWonBefore[winner] = true;
		}
		
		// Track largest jackpot
		if (winAmount > largestJackpot) {
			largestJackpot = winAmount;
		}
		
		// Reset for next round
		lastFinalizeTime = block.timestamp;
		uint256 currentRoundCompleted = round;
		round++;
		
		emit JackpotWon(winner, winAmount, currentRoundCompleted);
	}
    
	/**
     * @notice Get recent winners (for website display)
     */
    function getRecentWinners(uint256 count) external view returns (
        uint256[] memory roundIds,
        address[] memory winners,
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
        winners = new address[](actualCount);
        amounts = new uint256[](actualCount);
        timestamps = new uint256[](actualCount);
        claimedStatus = new bool[](actualCount);
        
        for (uint256 i = 0; i < actualCount; i++) {
            uint256 roundId = startRound + i;
            RoundInfo memory info = rounds[roundId];
            roundIds[i] = roundId;
            winners[i] = info.winner;
            amounts[i] = info.amount;
            timestamps[i] = info.timestamp;
            claimedStatus[i] = info.claimed;
        }
    }
    
    /**
     * @notice Get all jackpots won by a specific user
     */
    function getUserJackpots(address user) external view returns (
        uint256[] memory roundIds,
        uint256[] memory amounts,
        uint256[] memory timestamps,
        bool[] memory claimedStatus
    ) {
        uint256 count = 0;
        for (uint256 i = 0; i < round; i++) {
            if (rounds[i].winner == user && rounds[i].amount > 0) {
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
            if (rounds[i].winner == user && rounds[i].amount > 0) {
                roundIds[idx] = i;
                amounts[idx] = rounds[i].amount;
                timestamps[idx] = rounds[i].timestamp;
                claimedStatus[idx] = rounds[i].claimed;
                idx++;
            }
        }
    }
    
    /**
     * @notice Get all unclaimed jackpots
     */
    function getUnclaimedJackpots() external view returns (
        uint256[] memory roundIds,
        address[] memory winners,
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
        winners = new address[](unclaimedCount);
        amounts = new uint256[](unclaimedCount);
        timestamps = new uint256[](unclaimedCount);
        daysRemaining = new uint256[](unclaimedCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < round; i++) {
            if (!rounds[i].claimed && rounds[i].amount > 0) {
                roundIds[index] = i;
                winners[index] = rounds[i].winner;
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
		uint256 totalWonAmount,
		uint256 totalClaimedAmount,
		uint256 uniqueWinnerCount,
		uint256 largestJackpotAmount,
		uint256 currentPot,
		uint256 currentThreshold,
		bool jackpotReady
	) {
		totalRounds = round;
		totalWonAmount = totalWon;
		totalClaimedAmount = totalClaimed;
		uniqueWinnerCount = uniqueWinners.length;
		largestJackpotAmount = largestJackpot;
		currentPot = address(this).balance - _getTotalPendingClaims();
		currentThreshold = getCurrentThreshold();
		jackpotReady = snapshotTaken;
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
     * @notice Get list of unique winner addresses
     */
    function getUniqueWinners() external view returns (address[] memory) {
        return uniqueWinners;
    }
    
    /**
     * @notice Get top N winners by total amount won
     */
    function getTopWinners(uint256 count) external view returns (
        address[] memory topAddresses,
        uint256[] memory topAmounts
    ) {
        uint256 totalUnique = uniqueWinners.length;
        if (totalUnique == 0) {
            return (new address[](0), new uint256[](0));
        }
        
        uint256 resultCount = count > totalUnique ? totalUnique : count;
        
        address[] memory allWinners = new address[](totalUnique);
        uint256[] memory allAmounts = new uint256[](totalUnique);
        
        for (uint256 i = 0; i < totalUnique; i++) {
            allWinners[i] = uniqueWinners[i];
            allAmounts[i] = winnerHistory[uniqueWinners[i]];
        }
        
        // Simple bubble sort for small datasets
        for (uint256 i = 0; i < totalUnique; i++) {
            for (uint256 j = i + 1; j < totalUnique; j++) {
                if (allAmounts[j] > allAmounts[i]) {
                    uint256 tempAmount = allAmounts[i];
                    allAmounts[i] = allAmounts[j];
                    allAmounts[j] = tempAmount;
                    
                    address tempAddress = allWinners[i];
                    allWinners[i] = allWinners[j];
                    allWinners[j] = tempAddress;
                }
            }
        }
        
        topAddresses = new address[](resultCount);
        topAmounts = new uint256[](resultCount);
        
        for (uint256 i = 0; i < resultCount; i++) {
            topAddresses[i] = allWinners[i];
            topAmounts[i] = allAmounts[i];
        }
    }
	
    /**
     * @notice Claim jackpot winnings
     */
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "Nothing to claim");
        
        // Reset first (prevent reentrancy)
        claimable[msg.sender] = 0;
        totalClaimed += amount;
        
        // Update round claimed status
        for (uint256 i = 0; i < round; i++) {
            if (rounds[i].winner == msg.sender && !rounds[i].claimed) {
                rounds[i].claimed = true;
            }
        }
        
        // Transfer prize
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
        
        emit Claimed(msg.sender, amount);
    }
    
    /**
     * @notice Get total pending claims
     */
    function _getTotalPendingClaims() private view returns (uint256) {
        return totalWon - totalClaimed;
    }
    
    /**
     * @notice Get current pot size (minus pending claims)
     */
    function getPotSize() external view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 pending = _getTotalPendingClaims();
        return balance > pending ? balance - pending : 0;
    }
    
    /**
     * @notice Check if jackpot is ready to be finalized
     */
    function isJackpotReady() external view returns (bool) {
		return snapshotTaken;
	}
    
    /**
     * @notice Get potential winner prize
     */
    function getWinnerPrize() external view returns (uint256) {
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
        address winner,
        uint256 amount,
        uint256 timestamp,
        bool claimed
    ) {
        RoundInfo memory info = rounds[roundId];
        return (info.winner, info.amount, info.timestamp, info.claimed);
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
     */
    function emergencyClaim(address winner) external nonReentrant {
        require(claimable[winner] > 0, "No claim");
        
        // Find oldest unclaimed round for this winner
        bool hasOldUnclaimed = false;
        for (uint256 i = 0; i < round; i++) {
            if (rounds[i].winner == winner && 
                !rounds[i].claimed && 
                block.timestamp > rounds[i].timestamp + MAX_CLAIM_DELAY) {
                hasOldUnclaimed = true;
                break;
            }
        }
        
        require(hasOldUnclaimed, "No emergency claim");
        
        uint256 amount = claimable[winner];
        claimable[winner] = 0;
        totalClaimed += amount;
        
        (bool success,) = winner.call{value: amount}("");
        require(success, "Transfer failed");
        
        emit Claimed(winner, amount);
    }
    
    /**
     * @notice Prevent direct funding
     */
    receive() external payable {
        revert("Direct funding disabled");
    }
}
