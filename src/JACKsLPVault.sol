// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JACKs LP Vault - Liquidity Provider Rewards
 * @notice Part of the JACKs Pots ecosystem on Base.
 * @notice Handles the collection and distribution of rewards for liquidity providers.
 * @notice Operates autonomously once configured; no external control or owner intervention.
 * @dev Receives a share of sell taxes, tracks LP contributions, and finalizes rounds
 *      either when thresholds are reached or when a timeout period expires.
 */

interface IJACKsPools {
    function getLpValue() external view returns (uint256);
    function owner() external view returns (address);
}

contract JACKsLPVault is ReentrancyGuard {
    IJACKsPools public immutable TOKEN;
	address public LP_MANAGER;
    
    // Round management
    uint256 public currentRound;
    bool public snapshotTaken;
	uint256 public snapshotTimestamp;
	uint256 public snapshotBuffer;
	
	// Accounting for multi-round solvency
	uint256 public totalDistributed;
	uint256 public totalClaimed;
    
    // Buffer system (2 buffers alternating)
    uint256 public activeBuffer; // 0 or 1
    mapping(uint256 => mapping(address => uint256)) public bufferContributions; // buffer => user => ETH contributed
    mapping(uint256 => address[]) public bufferParticipants; // buffer => array of participants
    mapping(uint256 => mapping(address => bool)) public isInBuffer; // buffer => user => exists
 	
    // Round results
    struct RoundInfo {
        uint256 totalDistributed;
        uint256 winnersCount;
        uint256 timestamp;
        bool finalized;
    }
    mapping(uint256 => RoundInfo) public rounds;
    
    // User tracking
    mapping(address => uint256) public lifetimeContributions; // Total ever contributed
    mapping(uint256 => mapping(address => uint256)) public roundRewards; // round => user => reward
    mapping(uint256 => mapping(address => bool)) public hasClaimed; // round => user => claimed
    mapping(uint256 => address[]) public roundWinners;
	
    // Constants
    uint256 public constant TOP_WINNERS = 10; // Top 10 contributors (60% of pool)
	uint256 public constant SECONDARY_WINNERS = 90; // Ranks 11-100 (40% of pool)
	uint256 public constant TOTAL_WINNERS = 100; // Total winners per round
	uint256 public constant CLAIM_DEADLINE = 30 days;
	uint256 public constant MAX_PARTICIPANTS = 400; // Safety limit (gas optimized)
	
	// Stage LP thresholds
	uint256 private constant STAGE_2_LP_THRESHOLD = 2 ether;
	uint256 private constant STAGE_3_LP_THRESHOLD = 5 ether;
	uint256 private constant STAGE_4_LP_THRESHOLD = 10 ether;
	uint256 private constant STAGE_5_LP_THRESHOLD = 20 ether;

	// Stage 1: Requirements (LP < 2 ETH)
	uint256 private constant STAGE_1_MIN_LP_REQUIRED = 0.0086 ether;  // $30 @ $3500/ETH
	uint256 private constant STAGE_1_POT_THRESHOLD = 0.086 ether;     // $300 @ $3500/ETH

	// Stage 2: Requirements (LP 2-5 ETH)
	uint256 private constant STAGE_2_MIN_LP_REQUIRED = 0.01 ether;    // $35 @ $3500/ETH
	uint256 private constant STAGE_2_POT_THRESHOLD = 0.257 ether;     // $900 @ $3500/ETH

	// Stage 3: Requirements (LP 5-10 ETH)
	uint256 private constant STAGE_3_MIN_LP_REQUIRED = 0.011 ether;   // $40 @ $3500/ETH
	uint256 private constant STAGE_3_POT_THRESHOLD = 0.514 ether;     // $1,800 @ $3500/ETH

	// Stage 4: Requirements (LP 10-20 ETH)
	uint256 private constant STAGE_4_MIN_LP_REQUIRED = 0.013 ether;   // $45 @ $3500/ETH
	uint256 private constant STAGE_4_POT_THRESHOLD = 1.03 ether;      // $3,600 @ $3500/ETH

	// Stage 5: Requirements (LP > 20 ETH)
	uint256 private constant STAGE_5_MIN_LP_REQUIRED = 0.014 ether;   // $50 @ $3500/ETH
	uint256 private constant STAGE_5_POT_THRESHOLD = 1.71 ether;      // $6,000 @ $3500/ETH
    
    // Events
    event LPContributed(address indexed user, uint256 ethAmount, uint256 round);
	event LPContributionTracked(address indexed user, uint256 ethAmount, uint256 lifetimeTotal);
    event LPContributorEvicted(address indexed evicted, address indexed replacedBy, uint256 evictedAmount, uint256 newAmount, uint256 round);
	event SnapshotTaken(uint256 indexed round, uint256 participants, uint256 totalContributed);
    event RoundFinalized(uint256 indexed round, uint256 totalDistributed, uint256 winnersCount);
    event RewardClaimed(address indexed user, uint256 indexed round, uint256 amount);
    event Funded(address indexed from, uint256 amount, uint256 poolAfter);
	event BufferCleared(uint256 indexed bufferIndex, uint256 round);
    
    modifier onlyToken() {
        require(msg.sender == address(TOKEN), "Only token can call");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == TOKEN.owner(), "Only owner can call");
        _;
    }
    
    constructor(address _token) {
        TOKEN = IJACKsPools(_token);
        activeBuffer = 0;
        currentRound = 0;
    }
	
	/**
     * @notice Set LP Manager address (one-time only)
     */
    function setLpManager(address _lpManager) external onlyOwner {
        require(LP_MANAGER == address(0), "LP Manager already set");
        require(_lpManager != address(0), "Invalid address");
        LP_MANAGER = _lpManager;
    }
    
    // ============================================
    // CORE FUNCTIONS - LP CONTRIBUTION
    // ============================================
    
	/**
	 * @notice Find contributor with lowest contribution in buffer
	 * @dev Used for eviction when buffer is full
	 * @return lowestAddr Address with lowest contribution
	 * @return lowestAmount Lowest contribution amount
	 * @return lowestIdx Index in participants array
	 */
	function _findLowestContributor(uint256 bufferIndex)
		internal
		view
		returns (address lowestAddr, uint256 lowestAmount, uint256 lowestIdx)
	{
		address[] storage participants = bufferParticipants[bufferIndex];
		uint256 count = participants.length;
		
		require(count > 0, "No participants");

		lowestAddr = participants[0];
		lowestAmount = bufferContributions[bufferIndex][lowestAddr];
		lowestIdx = 0;

		for (uint256 i = 1; i < count; i++) {
			address user = participants[i];
			uint256 amount = bufferContributions[bufferIndex][user];
			
			if (amount < lowestAmount) {
				lowestAmount = amount;
				lowestAddr = user;
				lowestIdx = i;
				
				// Early exit if we find 0 (shouldn't happen but safety)
				if (lowestAmount == 0) break;
			}
		}
	}
	
    /**
	 * @notice Record LP contribution from user
	 * @dev Called by token contract when user adds LP through site
	 * @dev Accepts any amount - eligibility based on lifetime contributions
	 */
	function recordLpContribution(address user, uint256 ethAmount) external {
		require(
			msg.sender == address(TOKEN) || msg.sender == LP_MANAGER,
			"Only token or LP manager"
		);
		require(!snapshotTaken, "Snapshot already taken");
		
		// NO MINIMUM CHECK - accept any amount!
		
		// Track lifetime (always)
		lifetimeContributions[user] += ethAmount;
		
		// Check eligibility based on lifetime
		bool isEligible = lifetimeContributions[user] >= getMinLpRequired();
		
		if (isEligible) {
			uint256 bufferIndex = activeBuffer;

			// If user not already in this round's buffer
			if (!isInBuffer[bufferIndex][user]) {
				uint256 length = bufferParticipants[bufferIndex].length;

				if (length < MAX_PARTICIPANTS) {
					// Still room - add normally
					bufferParticipants[bufferIndex].push(user);
					isInBuffer[bufferIndex][user] = true;
					bufferContributions[bufferIndex][user] = ethAmount;
				} else {
					// Buffer full - check if we can evict someone
					(address lowestAddr, uint256 lowestAmount, uint256 lowestIdx) =
						_findLowestContributor(bufferIndex);

					// Safety: prevent self-eviction (shouldn't happen but paranoid check)
					require(lowestAddr != user, "Internal error: self-eviction");

					// If new contribution doesn't beat lowest, don't enter this round
					if (ethAmount <= lowestAmount) {
						emit LPContributionTracked(user, ethAmount, lifetimeContributions[user]);
						return;
					}

					// Evict: clear old user's data
					emit LPContributorEvicted(lowestAddr, user, lowestAmount, ethAmount, currentRound);
					
					bufferContributions[bufferIndex][lowestAddr] = 0;
					isInBuffer[bufferIndex][lowestAddr] = false;

					// Replace in array with new user
					bufferParticipants[bufferIndex][lowestIdx] = user;
					isInBuffer[bufferIndex][user] = true;
					bufferContributions[bufferIndex][user] = ethAmount;
				}
			} else {
				// Already in buffer - just increase contribution for this round
				bufferContributions[bufferIndex][user] += ethAmount;
			}

			emit LPContributed(user, ethAmount, currentRound);

			// Check if snapshot should be taken
			if (address(this).balance >= getPotThreshold()) {
				_takeSnapshot();
			}
		} else {
			// Not eligible yet - just track lifetime
			emit LPContributionTracked(user, ethAmount, lifetimeContributions[user]);
		}
	}
    
    /**
     * @notice Take snapshot of current contributors
     * @dev Locks the current buffer and prepares for distribution
     */
    function _takeSnapshot() internal {
        require(!snapshotTaken, "Snapshot already taken");
        require(bufferParticipants[activeBuffer].length > 0, "No participants");
        
        snapshotTaken = true;
		snapshotTimestamp = block.timestamp;
		snapshotBuffer = activeBuffer;
        
        emit SnapshotTaken(
            currentRound,
            bufferParticipants[activeBuffer].length,
            _getTotalContributions(activeBuffer)
        );
    }
    
    /**
	 * @notice Finalize round and calculate rewards for top 100
	 * @dev Distributes pot: 60% to top 10 (proportional), 40% to ranks 11-100 (proportional)
	 * @dev Participants can finalize immediately, anyone can finalize after 7 days
	 */
    function finalizeRound() external nonReentrant {
		require(snapshotTaken, "No snapshot taken");
		require(!rounds[currentRound].finalized, "Round already finalized");
		
		uint256 buffer = snapshotBuffer;
		
		// Anti-griefing: Only participants can finalize immediately          
		// BUT: Anyone can finalize after 7 days (prevents eternal lockup post-renounce)  
		bool isParticipant = bufferContributions[buffer][msg.sender] > 0;       
		bool isTimedOut = block.timestamp >= snapshotTimestamp + 7 days;               

		require(                
			isParticipant || isTimedOut, 
			"Only participants or wait 7 days"     
		);                          
		
		uint256 potAmount = address(this).balance - _getTotalPendingClaims();
        
        // Get top 50 contributors
		(address[] memory topContributors, uint256[] memory contributions) = _getTopContributors(buffer);

		// Ensure we have at least 1 winner
		require(topContributors.length > 0, "No valid contributions");

		// Calculate pool splits: 60% top 10, 40% rank 11-100
		uint256 topTierPot = (potAmount * 6000) / 10000; // 60%
		uint256 secondaryPot = potAmount - topTierPot;   // 40%

		// Determine actual winner counts
		uint256 topCount = topContributors.length < TOP_WINNERS ? topContributors.length : TOP_WINNERS;
		uint256 secondaryCount = topContributors.length > TOP_WINNERS ? 
			(topContributors.length < TOTAL_WINNERS ? topContributors.length - TOP_WINNERS : SECONDARY_WINNERS) : 0;

		// Calculate total contributions for top tier (ranks 1-10)
		uint256 totalTopContributions = 0;
		for (uint256 i = 0; i < topCount; i++) {
			totalTopContributions += contributions[i];
		}

		// Distribute 60% to top 10 (proportional)
		if (totalTopContributions > 0) {
			for (uint256 i = 0; i < topCount; i++) {
				uint256 reward = (topTierPot * contributions[i]) / totalTopContributions;
				roundRewards[currentRound][topContributors[i]] = reward;
			}
		}

		// Calculate total contributions for secondary tier (ranks 11-100)
		if (secondaryCount > 0) {
			uint256 totalSecondaryContributions = 0;
			for (uint256 i = topCount; i < topCount + secondaryCount; i++) {
				totalSecondaryContributions += contributions[i];
			}
			
			// Distribute 40% to ranks 11-100 (proportional)
			if (totalSecondaryContributions > 0) {
				for (uint256 i = topCount; i < topCount + secondaryCount; i++) {
					uint256 reward = (secondaryPot * contributions[i]) / totalSecondaryContributions;
					roundRewards[currentRound][topContributors[i]] += reward;
				}
			}
		}
		
		// Store all winners for this round (for cleanup)
        for (uint256 i = 0; i < topContributors.length; i++) {
            roundWinners[currentRound].push(topContributors[i]);
        }
        
         // Track total distributed amount
        totalDistributed += potAmount;
        
        // Mark round as finalized
        rounds[currentRound] = RoundInfo({
            totalDistributed: potAmount,
            winnersCount: topContributors.length,
            timestamp: block.timestamp,
            finalized: true
        });
        
        emit RoundFinalized(currentRound, potAmount, topContributors.length);
        
        // Start new round
        _startNewRound();
    }
    
    /**
     * @notice Start a new round
     * @dev Switches buffer, resets state
     */
    function _startNewRound() internal {
        // Switch to next buffer
        activeBuffer = 1 - activeBuffer;
        
        // Clear new active buffer
        _clearBuffer(activeBuffer);
        
        // Reset snapshot flag
        snapshotTaken = false;
        
        // Increment round
        currentRound++;
    }
    
    /**
     * @notice Clear a buffer
     */
    function _clearBuffer(uint256 bufferIndex) internal {
        address[] storage participants = bufferParticipants[bufferIndex];
        
        for (uint256 i = 0; i < participants.length; i++) {
            address user = participants[i];
            delete bufferContributions[bufferIndex][user];
            delete isInBuffer[bufferIndex][user];
        }
        
        delete bufferParticipants[bufferIndex];
		emit BufferCleared(bufferIndex, currentRound);
    }
    
	/**
	 * @notice Get total pending claims across all rounds
	 * @dev Used to calculate available pot without double-allocating
	 */
	function _getTotalPendingClaims() internal view returns (uint256) {
		return totalDistributed - totalClaimed;
	}
	
    /**
     * @notice Get top N contributors from a buffer
     * @dev Returns sorted list of top contributors
     */
    function _getTopContributors(uint256 bufferIndex) internal view returns (
        address[] memory topAddresses,
        uint256[] memory topContributions
    ) {
        address[] memory participants = bufferParticipants[bufferIndex];
        uint256 count = participants.length;
        uint256 topCount = count < TOTAL_WINNERS ? count : TOTAL_WINNERS;
        
        // Create arrays for sorting
        address[] memory sortedAddresses = new address[](count);
        uint256[] memory sortedContributions = new uint256[](count);
        
        // Copy data
        for (uint256 i = 0; i < count; i++) {
            sortedAddresses[i] = participants[i];
            sortedContributions[i] = bufferContributions[bufferIndex][participants[i]];
        }
        
        // Simple bubble sort (descending)
        for (uint256 i = 0; i < count; i++) {
            for (uint256 j = i + 1; j < count; j++) {
                if (sortedContributions[j] > sortedContributions[i]) {
                    // Swap contributions
                    uint256 tempAmount = sortedContributions[i];
                    sortedContributions[i] = sortedContributions[j];
                    sortedContributions[j] = tempAmount;
                    
                    // Swap addresses
                    address tempAddr = sortedAddresses[i];
                    sortedAddresses[i] = sortedAddresses[j];
                    sortedAddresses[j] = tempAddr;
                }
            }
        }
        
        // Return top N
        topAddresses = new address[](topCount);
        topContributions = new uint256[](topCount);
        
        for (uint256 i = 0; i < topCount; i++) {
            topAddresses[i] = sortedAddresses[i];
            topContributions[i] = sortedContributions[i];
        }
        
        return (topAddresses, topContributions);
    }
    
    /**
     * @notice Get total contributions in a buffer
     */
    function _getTotalContributions(uint256 bufferIndex) internal view returns (uint256 total) {
        address[] memory participants = bufferParticipants[bufferIndex];
        for (uint256 i = 0; i < participants.length; i++) {
            total += bufferContributions[bufferIndex][participants[i]];
        }
        return total;
    }
    
    // ============================================
    // CLAIM FUNCTIONS
    // ============================================
    
    /**
     * @notice Claim reward from a specific round
     */
    function claimReward(uint256 roundId) external nonReentrant {
        require(rounds[roundId].finalized, "Round not finalized");
        require(!hasClaimed[roundId][msg.sender], "Already claimed");
        require(roundRewards[roundId][msg.sender] > 0, "No reward");
        require(
            block.timestamp <= rounds[roundId].timestamp + CLAIM_DEADLINE,
            "Claim deadline passed"
        );
        
        uint256 reward = roundRewards[roundId][msg.sender];
        hasClaimed[roundId][msg.sender] = true;
		totalClaimed += reward;
        
        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "Transfer failed");
        
        emit RewardClaimed(msg.sender, roundId, reward);
    }
    
    /**
     * @notice Claim rewards from multiple rounds
     */
    function claimMultipleRewards(uint256[] calldata roundIds) external nonReentrant {
        uint256 totalReward = 0;
        
        for (uint256 i = 0; i < roundIds.length; i++) {
            uint256 roundId = roundIds[i];
            
            if (
                rounds[roundId].finalized &&
                !hasClaimed[roundId][msg.sender] &&
                roundRewards[roundId][msg.sender] > 0 &&
                block.timestamp <= rounds[roundId].timestamp + CLAIM_DEADLINE
            ) {
                uint256 reward = roundRewards[roundId][msg.sender];
                hasClaimed[roundId][msg.sender] = true;
                totalReward += reward;
				totalClaimed += reward;
                
                emit RewardClaimed(msg.sender, roundId, reward);
            }
        }
        
        require(totalReward > 0, "No rewards to claim");
        
        (bool success, ) = payable(msg.sender).call{value: totalReward}("");
        require(success, "Transfer failed");
    }
    
    // ============================================
    // FUNDING
    // ============================================
    
    /**
	  * @notice Receive LP reward pool funding from token contract
	  * @dev Called when sell tax is processed
	 */
	function onLpTaxReceived() external payable onlyToken {
		require(msg.value > 0, "No ETH sent");
        
        emit Funded(msg.sender, msg.value, address(this).balance);
        
        // Check if we should take snapshot
        uint256 availablePot = address(this).balance - _getTotalPendingClaims();
		if (!snapshotTaken && availablePot >= getPotThreshold()) {
            if (bufferParticipants[activeBuffer].length > 0) {
                _takeSnapshot();
            }
        }
    }
    
    // ============================================
    // STAGE SYSTEM (Dynamic Thresholds)
    // ============================================
    
    function getCurrentStage() public view returns (uint256) {
		uint256 lpValue = TOKEN.getLpValue();
		
		if (lpValue < STAGE_2_LP_THRESHOLD) return 1;
		if (lpValue < STAGE_3_LP_THRESHOLD) return 2;
		if (lpValue < STAGE_4_LP_THRESHOLD) return 3;
		if (lpValue < STAGE_5_LP_THRESHOLD) return 4;
		return 5;
	}
    
	/**
	 * @notice Get minimum lifetime LP required for eligibility
	 * @dev This is a lifetime threshold - once reached, user is eligible forever
	 * @dev User must still add LP each round to participate in that round
	 */
	
    function getMinLpRequired() public view returns (uint256) {
		uint256 stage = getCurrentStage();
		
		if (stage == 1) return STAGE_1_MIN_LP_REQUIRED;
		if (stage == 2) return STAGE_2_MIN_LP_REQUIRED;
		if (stage == 3) return STAGE_3_MIN_LP_REQUIRED;
		if (stage == 4) return STAGE_4_MIN_LP_REQUIRED;
		return STAGE_5_MIN_LP_REQUIRED;
	}
		
    function getPotThreshold() public view returns (uint256) {
		uint256 stage = getCurrentStage();
		
		if (stage == 1) return STAGE_1_POT_THRESHOLD;
		if (stage == 2) return STAGE_2_POT_THRESHOLD;
		if (stage == 3) return STAGE_3_POT_THRESHOLD;
		if (stage == 4) return STAGE_4_POT_THRESHOLD;
		return STAGE_5_POT_THRESHOLD;
	}
    
    // ============================================
    // VIEW FUNCTIONS
    // ============================================
    
    /**
     * @notice Get leaderboard - top contributors in current round
     */
    function getLeaderboard(uint256 count) external view returns (
		address[] memory addresses,
		uint256[] memory contributions,
		uint256[] memory estimatedRewards
	) {
		// Use snapshot buffer if snapshot taken, otherwise active buffer
		uint256 bufferIndex = snapshotTaken ? snapshotBuffer : activeBuffer;
		uint256 participants = bufferParticipants[bufferIndex].length;
        uint256 returnCount = participants < count ? participants : count;
        
        (address[] memory topAddresses, uint256[] memory topContributions) = _getTopContributors(bufferIndex);
        
        addresses = new address[](returnCount);
        contributions = new uint256[](returnCount);
        estimatedRewards = new uint256[](returnCount);
        
        // Calculate total for proportion
        uint256 totalTop = 0;
        for (uint256 i = 0; i < topAddresses.length; i++) {
            totalTop += topContributions[i];
        }
        
        uint256 potAmount = address(this).balance - _getTotalPendingClaims();
        
        for (uint256 i = 0; i < returnCount; i++) {
            addresses[i] = topAddresses[i];
            contributions[i] = topContributions[i];
            if (totalTop > 0) {
                estimatedRewards[i] = (potAmount * topContributions[i]) / totalTop;
            }
        }
        
        return (addresses, contributions, estimatedRewards);
    }
    
    /**
     * @notice Get user stats
     */
    function getUserStats(address user) external view returns (
		uint256 currentContribution,
		uint256 lifetimeContribution,
		uint256 currentRank,
		uint256 estimatedReward,
		uint256 unclaimedRewards
	) {
		// Use snapshot buffer if snapshot taken, otherwise active buffer
		uint256 bufferIndex = snapshotTaken ? snapshotBuffer : activeBuffer;
		currentContribution = bufferContributions[bufferIndex][user];
        lifetimeContribution = lifetimeContributions[user];
        
        // Calculate rank
        currentRank = 0;
        address[] memory participants = bufferParticipants[bufferIndex];
        for (uint256 i = 0; i < participants.length; i++) {
            if (bufferContributions[bufferIndex][participants[i]] > currentContribution) {
                currentRank++;
            }
        }
        currentRank++; // 1-indexed
        
        // Estimated reward
        if (currentContribution > 0 && currentRank <= TOP_WINNERS) {
            uint256 totalTop = _getTotalContributions(bufferIndex);
            uint256 availablePot = address(this).balance - _getTotalPendingClaims();
			if (totalTop > 0) {
				estimatedReward = (availablePot * currentContribution) / totalTop;
			}
        }
        
        // Unclaimed rewards
        for (uint256 i = 0; i < currentRound; i++) {
            if (!hasClaimed[i][user] && roundRewards[i][user] > 0) {
                if (block.timestamp <= rounds[i].timestamp + CLAIM_DEADLINE) {
                    unclaimedRewards += roundRewards[i][user];
                }
            }
        }
        
        return (currentContribution, lifetimeContribution, currentRank, estimatedReward, unclaimedRewards);
    }
    
    /**
     * @notice Get user's claimable rounds
     */
    function getClaimableRounds(address user) external view returns (
        uint256[] memory roundIds,
        uint256[] memory amounts
    ) {
        // Count claimable
        uint256 count = 0;
        for (uint256 i = 0; i < currentRound; i++) {
            if (
                rounds[i].finalized &&
                !hasClaimed[i][user] &&
                roundRewards[i][user] > 0 &&
                block.timestamp <= rounds[i].timestamp + CLAIM_DEADLINE
            ) {
                count++;
            }
        }
        
        roundIds = new uint256[](count);
        amounts = new uint256[](count);
        
        uint256 index = 0;
        for (uint256 i = 0; i < currentRound; i++) {
            if (
                rounds[i].finalized &&
                !hasClaimed[i][user] &&
                roundRewards[i][user] > 0 &&
                block.timestamp <= rounds[i].timestamp + CLAIM_DEADLINE
            ) {
                roundIds[index] = i;
                amounts[index] = roundRewards[i][user];
                index++;
            }
        }
        
        return (roundIds, amounts);
    }
    
	/**
	 * @notice Cleanup expired unclaimed rewards (anyone can call)
	 * @dev Marks expired claims as processed, freeing accounting
	 * @return recovered Amount of ETH freed for future rounds
	 */
	function cleanupExpiredClaims() external returns (uint256 recovered) {
		recovered = 0;
		
		for (uint256 i = 0; i < currentRound; i++) {
			RoundInfo storage info = rounds[i];
			
			// Skip if not finalized or not expired
			if (!info.finalized || block.timestamp <= info.timestamp + CLAIM_DEADLINE) {
				continue;
			}
			
			// Check all winners for this round (stored at finalization)
			address[] storage winners = roundWinners[i];

			for (uint256 j = 0; j < winners.length; j++) {
				address user = winners[j];
				
				// If user has unclaimed reward from this round
				if (!hasClaimed[i][user] && roundRewards[i][user] > 0) {
					uint256 amount = roundRewards[i][user];
					hasClaimed[i][user] = true;
					totalClaimed += amount;
					recovered += amount;
				}
			}
			
			// Clear winners array to free storage
			delete roundWinners[i];
		}
		
		// Recovered funds stay in contract for future rounds
		return recovered;
	}
	
    /**
     * @notice Get round info
     */
    function getRoundInfo(uint256 roundId) external view returns (
        uint256 roundDistributed,
        uint256 winnersCount,
        uint256 timestamp,
        bool finalized
    ) {
        RoundInfo memory info = rounds[roundId];
        return (info.totalDistributed, info.winnersCount, info.timestamp, info.finalized);
    }
    
    /**
     * @notice Get current round status
     */
    function getCurrentRoundStatus() external view returns (
		uint256 roundId,
		uint256 participants,
		uint256 poolBalance,
		uint256 threshold,
		bool snapshotTaken_,
		uint256 minLpRequired,
		uint256 stage
	) {
		// Use snapshot buffer if snapshot taken, otherwise active buffer
		uint256 bufferIndex = snapshotTaken ? snapshotBuffer : activeBuffer;
		return (
			currentRound,
			bufferParticipants[bufferIndex].length,
			address(this).balance - _getTotalPendingClaims(),
			getPotThreshold(),
			snapshotTaken,
			getMinLpRequired(),
			getCurrentStage()
		);
	}
	
	/**
     * @notice Get snapshot buffer index
     * @dev Returns which buffer is currently frozen for finalization
     * @return bufferIndex The snapshot buffer (0 or 1)
     */
    function getSnapshotBuffer() external view returns (uint256) {
        if (!snapshotTaken) {
            return activeBuffer; // No snapshot yet, would be current
        }
        // Snapshot buffer is the opposite of current active
        // (because _startNewRound swaps it after snapshot)
        return 1 - activeBuffer;
    }
	
	/**
	 * @notice Check if user is eligible for LP Reward Round
	 * @param user Address to check
	 * @return eligible True if user has reached lifetime threshold
	 */
	function isUserEligible(address user) external view returns (bool eligible) {
		return lifetimeContributions[user] >= getMinLpRequired();
	}

	/**
	 * @notice Get user's eligibility progress
	 * @param user Address to check
	 * @return currentLifetime Total lifetime contributions
	 * @return requiredForEligibility Minimum required to become eligible
	 * @return isEligible Whether user is currently eligible
	 * @return remainingToEligibility How much more needed (0 if eligible)
	 */
	function getUserEligibilityProgress(address user) external view returns (
		uint256 currentLifetime,
		uint256 requiredForEligibility,
		bool isEligible,
		uint256 remainingToEligibility
	) {
		currentLifetime = lifetimeContributions[user];
		requiredForEligibility = getMinLpRequired();
		isEligible = currentLifetime >= requiredForEligibility;
		
		if (isEligible) {
			remainingToEligibility = 0;
		} else {
			remainingToEligibility = requiredForEligibility - currentLifetime;
		}
		
		return (currentLifetime, requiredForEligibility, isEligible, remainingToEligibility);
	}
    
    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================
    
    /**
     * @notice Emergency snapshot trigger
     */
    function emergencySnapshot() external onlyOwner {
        require(!snapshotTaken, "Snapshot already taken");
        require(bufferParticipants[activeBuffer].length > 0, "No participants");
        _takeSnapshot();
    }
    
    receive() external payable {
        revert("Use onLPTaxReceived");
    }
}
