// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JACKs LP Vault - Liquidity Provider Rewards
 * @notice Part of the JACKs Pools ecosystem on Base.
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
	uint256 public snapshotRound;
	
	// Accounting for multi-round solvency
	uint256 public totalDistributed;
	uint256 public totalClaimed;
	
	// Payout address redirection (for contract wallets)
	mapping(address => address payable) public payoutAddress; 
    
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
    	
    // Constants
    uint256 public constant TOP_WINNERS = 10; // Top 10 contributors (60% of pool)
	uint256 public constant SECONDARY_WINNERS = 50; // Ranks 11-60 (40% of pool)
	uint256 public constant TOTAL_WINNERS = 60; // Total winners per round
	uint256 public constant CLAIM_DEADLINE = 30 days;
	uint256 public constant MAX_PARTICIPANTS = 400; // Safety limit (gas optimized)
	
	// Stage LP thresholds
	uint256 private constant STAGE_2_LP_THRESHOLD = 10 ether;
	uint256 private constant STAGE_3_LP_THRESHOLD = 50 ether;
	uint256 private constant STAGE_4_LP_THRESHOLD = 150 ether;
	uint256 private constant STAGE_5_LP_THRESHOLD = 500 ether;

	// Stage 1: Requirements (LP < 10 ETH)
	uint256 private constant STAGE_1_MIN_LP_REQUIRED = 0.0086 ether;  // $30 @ $3500/ETH
	uint256 private constant STAGE_1_POOL_THRESHOLD = 0.2 ether;

	// Stage 2: Requirements (LP 10-50 ETH)
	uint256 private constant STAGE_2_MIN_LP_REQUIRED = 0.01 ether;    // $35 @ $3500/ETH
	uint256 private constant STAGE_2_POOL_THRESHOLD = 0.75 ether;

	// Stage 3: Requirements (LP 50-150 ETH)
	uint256 private constant STAGE_3_MIN_LP_REQUIRED = 0.011 ether;   // $40 @ $3500/ETH
	uint256 private constant STAGE_3_POOL_THRESHOLD = 8 ether;

	// Stage 4: Requirements (LP 150-500 ETH)
	uint256 private constant STAGE_4_MIN_LP_REQUIRED = 0.013 ether;   // $45 @ $3500/ETH
	uint256 private constant STAGE_4_POOL_THRESHOLD = 15 ether;

	// Stage 5: Requirements (LP > 500 ETH)
	uint256 private constant STAGE_5_MIN_LP_REQUIRED = 0.014 ether;   // $50 @ $3500/ETH
	uint256 private constant STAGE_5_POOL_THRESHOLD = 35 ether;
    
    // Events
    event LPContributed(address indexed user, uint256 ethAmount, uint256 round);
	event LPContributionTracked(address indexed user, uint256 ethAmount, uint256 lifetimeTotal);
    event LPContributorEvicted(address indexed evicted, address indexed replacedBy, uint256 evictedAmount, uint256 newAmount, uint256 round);
	event SnapshotTaken(uint256 indexed round, uint256 participants, uint256 totalContributed);
    event SnapshotReset(uint256 indexed round, string reason);
	event LpSnapshotAutoResetTimeout(uint256 indexed round, uint256 snapshotTimestamp, uint256 resetTimestamp);
	event ExpiredClaimsCleaned(uint256 indexed round, uint256 recoveredAmount, uint256 winnersProcessed);
	event RoundFinalized(uint256 indexed round, uint256 totalDistributed, uint256 winnersCount, address[] winners);
    event RewardClaimed(address indexed claimant, address indexed recipient, uint256 indexed round, uint256 amount);
    event Funded(address indexed from, uint256 amount, uint256 poolAfter);
	event BufferCleared(uint256 indexed bufferIndex, uint256 round);
	event PayoutAddressSet(address indexed user, address indexed payoutAddress);
    
    modifier onlyToken() {
        require(msg.sender == address(TOKEN), "Only token can call");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == TOKEN.owner(), "Only owner can call");
        _;
    }
    
    constructor(address _token) {
        require(_token != address(0), "Zero token");
        try IJACKsPools(_token).getLpValue() returns (uint256) {
            // Token contract valid
        } catch {
            revert("Invalid token contract");
        }
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
	 * @dev Called by LP_MANAGER (or token contract) when user adds LP through site
	 * @dev Accepts any amount - eligibility based on lifetime contributions
	 * @dev Lifetime eligibility only unlocks the ability to enter rounds.
	 *      User must still add LP during the active round to appear in that round's buffer.
	 */
	function recordLpContribution(address user, uint256 ethAmount) external {
		require(
			msg.sender == address(TOKEN) || msg.sender == LP_MANAGER,
			"Only token or LP manager"
		);
						
		// Track lifetime (always)
		lifetimeContributions[user] += ethAmount;
		
		// Check eligibility based on lifetime
		bool isEligible = lifetimeContributions[user] >= getMinLpRequired();
		
		// Auto-reset snapshot if stuck for 14 days (outside eligibility check)
		if (snapshotTaken && block.timestamp > snapshotTimestamp + 14 days) {
			snapshotTaken = false;
			emit LpSnapshotAutoResetTimeout(snapshotRound, snapshotTimestamp, block.timestamp);
			emit SnapshotReset(snapshotRound, "14 day timeout");
		}

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

				// Check snapshot with availablePool (not raw balance!)
				uint256 _rcBal = address(this).balance;
				uint256 _rcPending = _getTotalPendingClaims();
				uint256 availablePool = _rcBal > _rcPending ? _rcBal - _rcPending : 0;
				if (!snapshotTaken && availablePool >= getPoolThreshold()) {
					if (bufferParticipants[activeBuffer].length > 0) {
						_takeSnapshot();
					}
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
		snapshotRound = currentRound;
		snapshotBuffer = activeBuffer;
        
        emit SnapshotTaken(
            snapshotRound,
            bufferParticipants[snapshotBuffer].length,
			_getTotalContributions(snapshotBuffer)
        );
		
		// Move to next buffer immediately
		activeBuffer = 1 - activeBuffer;
		_clearBuffer(activeBuffer);
		
		// Next round starts NOW
		currentRound++;

    }
    
    /**
	 * @notice Finalize round and calculate rewards for top 60
	 * @dev Distributes pool: 60% to top 10 (proportional), 40% to ranks 11-60 (proportional)
	 * @dev Participants can finalize immediately, anyone can finalize after 7 days
	 */
    function finalizeRound() external nonReentrant {
		require(snapshotTaken, "No snapshot taken");
		require(!rounds[snapshotRound].finalized, "Round already finalized");
		
		uint256 buffer = snapshotBuffer;
		
		// Finalization is participant-gated for 7 days to reduce griefing.
		// After 7 days anyone can finalize to prevent stuck rewards after renounce. 
		bool isParticipant = bufferContributions[buffer][msg.sender] > 0;       
		bool isTimedOut = block.timestamp >= snapshotTimestamp + 7 days;               

		require(                
			isParticipant || isTimedOut, 
			"Only participants or wait 7 days"     
		);                          
		
		uint256 poolAmount = address(this).balance - _getTotalPendingClaims();
		require(poolAmount > 0, "Nothing to distribute");
        
        // Get top 60 contributors
		(address[] memory topContributors, uint256[] memory contributions) = _getTopContributors(buffer);		// Ensure we have at least 1 winner
		if (topContributors.length == 0) {
			snapshotTaken = false;
			emit SnapshotReset(snapshotRound, "No valid contributions");
			return;
		}

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
				// Combined: (poolAmount * 6000 * contrib) / (10000 * total)
				uint256 reward = (poolAmount * 6000 * contributions[i]) / (10000 * totalTopContributions);
				roundRewards[snapshotRound][topContributors[i]] = reward;
			}
		}

		// Calculate total contributions for secondary tier (ranks 11-60)
		if (secondaryCount > 0) {
			uint256 totalSecondaryContributions = 0;
			for (uint256 i = topCount; i < topCount + secondaryCount; i++) {
				totalSecondaryContributions += contributions[i];
			}
			
			// Distribute 40% to ranks 11-60 (proportional)
			if (totalSecondaryContributions > 0) {
				for (uint256 i = topCount; i < topCount + secondaryCount; i++) {
					// Combined: (poolAmount * 4000 * contrib) / (10000 * total)
					uint256 reward = (poolAmount * 4000 * contributions[i]) / (10000 * totalSecondaryContributions);
					roundRewards[snapshotRound][topContributors[i]] += reward;
				}
			}
		}
		
			// Track actual distributed amount (not poolAmount - avoids integer division dust)
			uint256 actualDistributed = 0;
			for (uint256 i = 0; i < topCount + secondaryCount; i++) {
				actualDistributed += roundRewards[snapshotRound][topContributors[i]];
			}
			totalDistributed += actualDistributed;
			
			// Mark round as finalized
			rounds[snapshotRound] = RoundInfo({
				totalDistributed: actualDistributed,
				winnersCount: topContributors.length,
				timestamp: block.timestamp,
				finalized: true
			});
			
			// Emit winners in event 
			emit RoundFinalized(snapshotRound, actualDistributed, topContributors.length, topContributors);
        
			// Allow next snapshot
			snapshotTaken = false;
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
	 * @dev Used to calculate available pool without double-allocating
	 */
	function _getTotalPendingClaims() internal view returns (uint256) {
		return totalDistributed - totalClaimed;
	}
	
    /**
	 * @notice Get top contributors from a buffer (optimized for large participant counts)
	 * @dev Single-pass insertion sort maintaining top K sorted descending
	 * @dev Complexity: O(n × k) where n=participants, k=60
	 * @dev Gas: ~500k-1M for 400 participants (vs 19M bubble sort)
	 */
	function _getTopContributors(uint256 bufferIndex)
		internal
		view
		returns (address[] memory topAddresses, uint256[] memory topContributions)
	{
		address[] memory participants = bufferParticipants[bufferIndex];
		uint256 n = participants.length;

		if (n == 0) {
			return (new address[](0), new uint256[](0));
		}

		uint256 k = TOTAL_WINNERS;
		if (n < k) k = n;

		// Temporary top-k arrays (kept sorted desc)
		address[] memory topA = new address[](k);
		uint256[] memory topV = new uint256[](k);
		uint256 topSize = 0;

		for (uint256 i = 0; i < n; i++) {
			address user = participants[i];
			uint256 amt = bufferContributions[bufferIndex][user];
			if (amt == 0) continue;

			// Case 1: still filling top list
			if (topSize < k) {
				uint256 pos = topSize;

				// Shift right until correct position found
				while (pos > 0 && amt > topV[pos - 1]) {
					topA[pos] = topA[pos - 1];
					topV[pos] = topV[pos - 1];
					pos--;
				}

				topA[pos] = user;
				topV[pos] = amt;
				topSize++;
				continue;
			}

			// Case 2: already full => only insert if beats current smallest (last)
			if (amt <= topV[k - 1]) continue;

			uint256 p = k - 1;

			// Shift right from end until correct position
			while (p > 0 && amt > topV[p - 1]) {
				topA[p] = topA[p - 1];
				topV[p] = topV[p - 1];
				p--;
			}

			topA[p] = user;
			topV[p] = amt;
		}

		// Shrink output if we skipped zeros
		topAddresses = new address[](topSize);
		topContributions = new uint256[](topSize);
		for (uint256 j = 0; j < topSize; j++) {
			topAddresses[j] = topA[j];
			topContributions[j] = topV[j];
		}
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
	
	/**
	 * @notice Internal helper to get top N contributors (view-only, supports up to 100)
	 * @dev Extended version for Top 100 visibility - used ONLY by view functions
	 * @param bufferIndex Buffer to query (0 or 1)
	 * @param limit Maximum entries to return (clamped to [1, 100])
	 * @return topAddresses Sorted addresses (descending by contribution)
	 * @return topContributions Sorted contributions (descending)
	 */
	function _getTopContributorsLimited(
		uint256 bufferIndex,
		uint256 limit
	) internal view returns (
		address[] memory topAddresses,
		uint256[] memory topContributions
	) {
		require(bufferIndex < 2, "Invalid buffer"); // VALIDATION ADDED
		
		address[] memory participants = bufferParticipants[bufferIndex];
		uint256 n = participants.length;

		if (n == 0) {
			return (new address[](0), new uint256[](0));
		}

		// Clamp limit to [1, 100]
		uint256 k = limit;
		if (k < 1) k = 1;
		if (k > 100) k = 100;
		if (n < k) k = n;

		// Temporary top-k arrays (kept sorted desc)
		address[] memory topA = new address[](k);
		uint256[] memory topV = new uint256[](k);
		uint256 topSize = 0;

		for (uint256 i = 0; i < n; i++) {
			address user = participants[i];
			uint256 amt = bufferContributions[bufferIndex][user];
			if (amt == 0) continue;

			// Case 1: still filling top list
			if (topSize < k) {
				uint256 pos = topSize;

				// Shift right until correct position found
				while (pos > 0 && amt > topV[pos - 1]) {
					topA[pos] = topA[pos - 1];
					topV[pos] = topV[pos - 1];
					pos--;
				}

				topA[pos] = user;
				topV[pos] = amt;
				topSize++;
				continue;
			}

			// Case 2: already full => only insert if beats current smallest (last)
			if (amt <= topV[k - 1]) continue;

			uint256 p = k - 1;

			// Shift right from end until correct position
			while (p > 0 && amt > topV[p - 1]) {
				topA[p] = topA[p - 1];
				topV[p] = topV[p - 1];
				p--;
			}

			topA[p] = user;
			topV[p] = amt;
		}

		// Shrink output if we skipped zeros
		topAddresses = new address[](topSize);
		topContributions = new uint256[](topSize);
		for (uint256 j = 0; j < topSize; j++) {
			topAddresses[j] = topA[j];
			topContributions[j] = topV[j];
		}
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
		
		// Determine recipient (use payout address if set)
		address payable recipient = payoutAddress[msg.sender] != address(0)
			? payoutAddress[msg.sender]
			: payable(msg.sender);
		
		hasClaimed[roundId][msg.sender] = true;
		totalClaimed += reward;
		
		(bool success, ) = recipient.call{value: reward}("");
		require(success, "Transfer failed");
				
		emit RewardClaimed(msg.sender, recipient, roundId, reward);
	}
    
    /**
	 * @notice Claim rewards from multiple rounds
	 */
	function claimMultipleRewards(uint256[] calldata roundIds) external nonReentrant {
		uint256 totalReward = 0;
		
		// Determine recipient once (gas savings)
		address payable recipient = payoutAddress[msg.sender] != address(0)
			? payoutAddress[msg.sender]
			: payable(msg.sender);
		
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
				
				// Enhanced event for each round
				emit RewardClaimed(msg.sender, recipient, roundId, reward);
			}
		}
		
		require(totalReward > 0, "No rewards to claim");
		
		(bool success, ) = recipient.call{value: totalReward}("");
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
        uint256 _rcBal = address(this).balance;
		uint256 _rcPending = _getTotalPendingClaims();
		uint256 availablePool = _rcBal > _rcPending ? _rcBal - _rcPending : 0;
		if (!snapshotTaken && availablePool >= getPoolThreshold()) {
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
		
    function getPoolThreshold() public view returns (uint256) {
		uint256 stage = getCurrentStage();
		
		if (stage == 1) return STAGE_1_POOL_THRESHOLD;
		if (stage == 2) return STAGE_2_POOL_THRESHOLD;
		if (stage == 3) return STAGE_3_POOL_THRESHOLD;
		if (stage == 4) return STAGE_4_POOL_THRESHOLD;
		return STAGE_5_POOL_THRESHOLD;
	}
    
    // ============================================
    // VIEW FUNCTIONS
    // ============================================
        
	/**
	 * @notice Get leaderboard from specified buffer (supports Top 100)
	 * @dev Generic function - can query any buffer (active or snapshot)
	 * @dev VALIDATION: bufferIndex must be 0 or 1, count must be 1-100
	 * @dev Top 100 visibility: rank 1-100 visible, only rank 1-60 get rewards
	 * @param bufferIndex Buffer to query (0 or 1)
	 * @param count Number of top contributors to return (1-100)
	 * @return addresses Array of contributor addresses (sorted DESC)
	 * @return contributions Array of ETH contributions
	 * @return estimatedRewards Estimated rewards (0 for rank > 60)
	 * @return availablePoolUsedForEstimation Available pool used for calculations
	 */
	function getLeaderboardForBuffer(
		uint256 bufferIndex,
		uint256 count
	) public view returns (
		address[] memory addresses,
		uint256[] memory contributions,
		uint256[] memory estimatedRewards,
		uint256 availablePoolUsedForEstimation
	) {
		require(bufferIndex < 2, "Invalid buffer");
		require(count >= 1 && count <= 100, "Invalid count");
		
		// Get top contributors (up to 100)
		(address[] memory topAddrs, uint256[] memory topContribs) = 
			_getTopContributorsLimited(bufferIndex, count);
		
		uint256 returnCount = topAddrs.length;
		
		addresses = new address[](returnCount);
		contributions = new uint256[](returnCount);
		estimatedRewards = new uint256[](returnCount);
		
		// UNDERFLOW PROTECTION
		uint256 pending = _getTotalPendingClaims();
		uint256 bal = address(this).balance;
		availablePoolUsedForEstimation = bal > pending ? bal - pending : 0;
		
		// Determine actual winner counts
		uint256 topCount = returnCount < TOP_WINNERS ? returnCount : TOP_WINNERS;
		uint256 secondaryCount = returnCount > TOP_WINNERS ? 
			(returnCount < TOTAL_WINNERS ? returnCount - TOP_WINNERS : SECONDARY_WINNERS) : 0;
		
		// Calculate top tier total (ranks 1-10)
		uint256 topTierTotal = 0;
		for (uint256 i = 0; i < topCount; i++) {
			topTierTotal += topContribs[i];
		}
		
		// Calculate secondary tier total (ranks 11-60)
		uint256 secondaryTotal = 0;
		for (uint256 i = topCount; i < topCount + secondaryCount; i++) {
			secondaryTotal += topContribs[i];
		}
		
		// Assign data with tier-aware reward estimation
		for (uint256 i = 0; i < returnCount; i++) {
			addresses[i] = topAddrs[i];
			contributions[i] = topContribs[i];
			
			// IMPORTANT: estimatedRewards calculated ONLY for rank 1-60
			// Rank 61-100: set explicitly to 0
			if (i < topCount && topTierTotal > 0) {
				// Top 10: share of 60% pool
				estimatedRewards[i] = (availablePoolUsedForEstimation * 6000 * topContribs[i]) / (10000 * topTierTotal);
			} else if (i >= topCount && i < topCount + secondaryCount && secondaryTotal > 0) {
				// Ranks 11-60: share of 40% pool
				estimatedRewards[i] = (availablePoolUsedForEstimation * 4000 * topContribs[i]) / (10000 * secondaryTotal);
			} else {
				// Rank 61-100: no rewards
				estimatedRewards[i] = 0;
			}
		}
		
		return (addresses, contributions, estimatedRewards, availablePoolUsedForEstimation);
	}
	
	/**
	 * @notice Convenience wrapper for active buffer leaderboard
	 * @dev Calls getLeaderboardForBuffer(activeBuffer, count)
	 */
	function getActiveBufferLeaderboard(uint256 count) external view returns (
		address[] memory addresses,
		uint256[] memory contributions,
		uint256[] memory estimatedRewards,
		uint256 availablePoolUsedForEstimation
	) {
		return getLeaderboardForBuffer(activeBuffer, count);
	}
	
	/**
	 * @notice Convenience wrapper for snapshot buffer leaderboard
	 * @dev Calls getLeaderboardForBuffer(snapshotBuffer, count)
	 * @dev Reverts if no snapshot taken
	 */
	function getSnapshotBufferLeaderboard(uint256 count) external view returns (
		address[] memory addresses,
		uint256[] memory contributions,
		uint256[] memory estimatedRewards,
		uint256 availablePoolUsedForEstimation
	) {
		require(snapshotTaken, "No snapshot taken");
		return getLeaderboardForBuffer(snapshotBuffer, count);
	}
	
	/**
	 * @notice Get user's position in a specific buffer
	 * @dev OPTIMIZED: Only searches top 60 list, doesn't iterate all 400 participants
	 * @param bufferIndex Buffer to check (0 or 1)
	 * @param user Address to check
	 * @return contribution User's total contribution in this buffer
	 * @return rank User's rank (1-60 if in rewards, 0 if outside top 60)
	 * @return tier Reward tier: 0=no rewards, 1=top10 (60%), 2=secondary (40%)
	 * @return isEligible Has user met lifetime LP threshold?
	 */
	function getUserBufferPosition(
		uint256 bufferIndex,
		address user
	) external view returns (
		uint256 contribution,
		uint256 rank,
		uint8 tier,
		bool isEligible
	) {
		require(bufferIndex < 2, "Invalid buffer");
		
		contribution = bufferContributions[bufferIndex][user];
		isEligible = lifetimeContributions[user] >= getMinLpRequired();
		
		// Get top 60 list only (optimized) - FIX UNUSED VARIABLE WARNING
		(address[] memory topAddrs,) = _getTopContributors(bufferIndex);
		
		// Search for user in top 60
		rank = 0;
		for (uint256 i = 0; i < topAddrs.length; i++) {
			if (topAddrs[i] == user) {
				rank = i + 1; // 1-indexed
				break;
			}
		}
		
		// Calculate tier
		if (rank == 0) {
			tier = 0; // Outside top 60
		} else if (rank <= TOP_WINNERS) {
			tier = 1; // Top 10 (60% pool)
		} else {
			tier = 2; // Ranks 11-60 (40% pool)
		}
		
		return (contribution, rank, tier, isEligible);
	}
	
	/**
	 * @notice Get entry cutoffs for reward tiers in a buffer
	 * @dev Shows minimum contribution needed for rewards
	 * @param bufferIndex Buffer to check (0 or 1)
	 * @return top10Cutoff Minimum ETH to be in top 10 (0 if < 10 participants)
	 * @return top60Cutoff Minimum ETH to be in top 60 (0 if < 60 participants)
	 * @return participantsCount Total competitors in this buffer
	 */
	function getBufferCutoffs(uint256 bufferIndex) external view returns (
		uint256 top10Cutoff,
		uint256 top60Cutoff,
		uint256 participantsCount
	) {
		require(bufferIndex < 2, "Invalid buffer");
		
		(address[] memory topAddrs, uint256[] memory topContribs) = _getTopContributors(bufferIndex);
		participantsCount = bufferParticipants[bufferIndex].length;
		
		top10Cutoff = (topAddrs.length >= TOP_WINNERS) ? topContribs[TOP_WINNERS - 1] : 0;
		top60Cutoff = (topAddrs.length >= TOTAL_WINNERS) ? topContribs[TOTAL_WINNERS - 1] : 0;
		
		return (top10Cutoff, top60Cutoff, participantsCount);
	}
	
	/**
	 * @notice Get complete round state in single call
	 * @dev Batch info for dashboard/header display
	 * @return currentStage Current stage (1-5) based on LP value
	 * @return currentRoundNum Current round number
	 * @return isSnapshotTaken Is a snapshot frozen and awaiting finalize?
	 * @return activeBufferNum Which buffer is currently active (0 or 1)
	 * @return snapshotBufferNum Which buffer is frozen (if snapshot taken)
	 * @return poolThreshold ETH needed to trigger next snapshot
	 * @return availablePool Current pool size (minus pending claims)
	 * @return pendingClaims Total unclaimed rewards from past rounds
	 * @return minLpRequired Lifetime LP needed for eligibility
	 * @return activeParticipants Competitors in active buffer
	 * @return snapshotParticipants Competitors in snapshot buffer (0 if no snapshot)
	 */
	function getRoundState() external view returns (
		uint256 currentStage,
		uint256 currentRoundNum,
		bool isSnapshotTaken,
		uint256 activeBufferNum,
		uint256 snapshotBufferNum,
		uint256 poolThreshold,
		uint256 availablePool,
		uint256 pendingClaims,
		uint256 minLpRequired,
		uint256 activeParticipants,
		uint256 snapshotParticipants
	) {
		currentStage = getCurrentStage();
		currentRoundNum = currentRound;
		isSnapshotTaken = snapshotTaken;
		activeBufferNum = activeBuffer;
		snapshotBufferNum = snapshotTaken ? snapshotBuffer : activeBuffer;
		poolThreshold = getPoolThreshold();
		
		// UNDERFLOW PROTECTION
		pendingClaims = _getTotalPendingClaims();
		uint256 bal = address(this).balance;
		availablePool = bal > pendingClaims ? bal - pendingClaims : 0;
		
		minLpRequired = getMinLpRequired();
		activeParticipants = bufferParticipants[activeBuffer].length;
		snapshotParticipants = snapshotTaken ? bufferParticipants[snapshotBuffer].length : 0;
		
		return (
			currentStage,
			currentRoundNum,
			isSnapshotTaken,
			activeBufferNum,
			snapshotBufferNum,
			poolThreshold,
			availablePool,
			pendingClaims,
			minLpRequired,
			activeParticipants,
			snapshotParticipants
		);
	}
	
	/**
	 * @notice Get progress toward next snapshot
	 * @dev Powers progress bars and countdown UI
	 * @return currentPool Current available pool (minus pending claims)
	 * @return poolThreshold ETH needed to trigger snapshot
	 * @return progressBps Progress in basis points (0-10000, for percentage)
	 * @return remainingToThreshold ETH still needed
	 * @return canSnapshot Can snapshot be taken right now?
	 */
	function getSnapshotProgress() external view returns (
		uint256 currentPool,
		uint256 poolThreshold,
		uint256 progressBps,
		uint256 remainingToThreshold,
		bool canSnapshot
	) {
		// UNDERFLOW PROTECTION
		uint256 pending = _getTotalPendingClaims();
		uint256 bal = address(this).balance;
		currentPool = bal > pending ? bal - pending : 0;
		
		poolThreshold = getPoolThreshold();
		
		// Division by zero protection
		if (poolThreshold == 0) {
			progressBps = 0;
			remainingToThreshold = 0;
			canSnapshot = false;
		} else if (currentPool >= poolThreshold) {
			progressBps = 10000; // 100%
			remainingToThreshold = 0;
			canSnapshot = !snapshotTaken && bufferParticipants[activeBuffer].length > 0;
		} else {
			progressBps = (currentPool * 10000) / poolThreshold;
			remainingToThreshold = poolThreshold - currentPool;
			canSnapshot = false;
		}
		
		return (currentPool, poolThreshold, progressBps, remainingToThreshold, canSnapshot);
	}
	        
	/**
	 * @notice Get unclaimed rewards for a user within a round range (paginated)
	 * @dev getUserStats().unclaimedRewards is disabled (unbounded loop, immutable protocol).
	 *      Use this function for accurate, bounded queries.
	 *      CLAIM_DEADLINE is 30 days — only recent rounds can have claimable rewards.
	 *      fromRound/toRound should be determined by indexer from RoundFinalized events,
	 *      not hardcoded — round frequency varies by stage and trading activity.
	 * @param user Address to check
	 * @param fromRound Start round (inclusive)
	 * @param toRound End round (exclusive, auto-capped at currentRound)
	 * @return total Sum of unclaimed non-expired rewards in range
	 */
	function getUnclaimedRewardsInRange(
		address user,
		uint256 fromRound,
		uint256 toRound
	) external view returns (uint256 total) {
		if (toRound > currentRound) toRound = currentRound;
		require(fromRound <= toRound, "Invalid range");

		for (uint256 i = fromRound; i < toRound; i++) {
			if (
				!hasClaimed[i][user] &&
				roundRewards[i][user] > 0 &&
				block.timestamp <= rounds[i].timestamp + CLAIM_DEADLINE
			) {
				total += roundRewards[i][user];
			}
		}
	}

	/**
	 * @notice Get user's claimable rounds within a range (paginated)
	 * @dev getClaimableRounds() scans 0..currentRound and becomes slow over time.
	 *      Use this for bounded, predictable gas in long-running protocols.
	 *      fromRound/toRound should be determined by indexer from RoundFinalized events,
	 *      not hardcoded — round frequency varies by stage and trading activity.
	 * @param user Address to check
	 * @param fromRound Start round (inclusive)
	 * @param toRound End round (exclusive, auto-capped at currentRound)
	 */
	function getClaimableRoundsInRange(
		address user,
		uint256 fromRound,
		uint256 toRound
	) external view returns (
		uint256[] memory roundIds,
		uint256[] memory amounts
	) {
		if (toRound > currentRound) toRound = currentRound;
		require(fromRound <= toRound, "Invalid range");

		uint256 count = 0;
		for (uint256 i = fromRound; i < toRound; i++) {
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
		uint256 idx = 0;

		for (uint256 i = fromRound; i < toRound; i++) {
			if (
				rounds[i].finalized &&
				!hasClaimed[i][user] &&
				roundRewards[i][user] > 0 &&
				block.timestamp <= rounds[i].timestamp + CLAIM_DEADLINE
			) {
				roundIds[idx] = i;
				amounts[idx] = roundRewards[i][user];
				idx++;
			}
		}

		return (roundIds, amounts);
	}

	/**
	 * @notice Cleanup expired claims for a specific round
	 * @dev Permissive: processes provided winners, verifies via roundRewards
	 * @param roundId Round to cleanup
	 * @param winners Array of winner addresses from RoundFinalized event
	 * @return recovered Amount of ETH freed
	 */
	function cleanupExpiredClaimsForRound(
		uint256 roundId,
		address[] calldata winners
	) public returns (uint256 recovered) {
		require(roundId < currentRound, "Invalid round");
		
		RoundInfo storage info = rounds[roundId];
		
		// Skip if not finalized or not expired
		if (!info.finalized) return 0;
		if (block.timestamp <= info.timestamp + CLAIM_DEADLINE) return 0;
		
		recovered = 0;
		uint256 winnersProcessed = 0;
		
		for (uint256 i = 0; i < winners.length; i++) {
			address user = winners[i];
			
			// Anti-griefing: only process if user actually has a reward
			uint256 amount = roundRewards[roundId][user];
			if (amount == 0) continue;
			
			// Skip if already claimed
			if (hasClaimed[roundId][user]) continue;
			
			// Mark as handled (prevents future claim)
			hasClaimed[roundId][user] = true;
			totalClaimed += amount;
			
			recovered += amount;
			winnersProcessed++;
		}
		
		if (recovered > 0) {
			emit ExpiredClaimsCleaned(roundId, recovered, winnersProcessed);
		}
		
		return recovered;
	}

	/**
	 * @notice Cleanup expired claims for multiple rounds (batched)
	 * @param roundIds Array of round IDs to cleanup
	 * @param winnersPerRound 2D array: winnersPerRound[i] = winners for roundIds[i]
	 * @return recovered Total amount of ETH freed
	 */
	function cleanupExpiredClaimsBatch(
		uint256[] calldata roundIds,
		address[][] calldata winnersPerRound
	) external returns (uint256 recovered) {
		require(roundIds.length == winnersPerRound.length, "Length mismatch");
		
		recovered = 0;
		
		for (uint256 i = 0; i < roundIds.length; i++) {
			recovered += cleanupExpiredClaimsForRound(roundIds[i], winnersPerRound[i]);
		}
		
		return recovered;
	}
		
    /**
	 * @notice Get expired rounds within a range (paginated)
	 * @dev getExpiredRounds() scans 0..currentRound and becomes slow over time.
	 *      Use this for bounded, predictable gas in long-running protocols.
	 * @param fromRound Start round (inclusive)
	 * @param toRound End round (exclusive, auto-capped at currentRound)
	 */
	function getExpiredRoundsInRange(
		uint256 fromRound,
		uint256 toRound
	) external view returns (uint256[] memory roundIds) {
		if (toRound > currentRound) toRound = currentRound;
		require(fromRound <= toRound, "Invalid range");

		uint256 count = 0;
		for (uint256 i = fromRound; i < toRound; i++) {
			if (
				rounds[i].finalized &&
				block.timestamp > rounds[i].timestamp + CLAIM_DEADLINE
			) {
				count++;
			}
		}

		roundIds = new uint256[](count);
		uint256 idx = 0;

		for (uint256 i = fromRound; i < toRound; i++) {
			if (
				rounds[i].finalized &&
				block.timestamp > rounds[i].timestamp + CLAIM_DEADLINE
			) {
				roundIds[idx] = i;
				idx++;
			}
		}

		return roundIds;
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
	
    receive() external payable {
        revert("Use onLpTaxReceived");
    }
}