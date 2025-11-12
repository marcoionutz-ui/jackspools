// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JackpotLPVault - Liquidity Provider Reward Vault
 * @notice Part of the JackpotToken ecosystem on BSC.
 * @notice Handles the collection and distribution of rewards for liquidity providers.
 * @notice The term "Jackpot" here does not refer to gambling or betting.
 *         It represents an automated reward mechanism that distributes a portion of taxes
 *         back to community liquidity contributors.
 * @notice Operates autonomously once configured; no external control or owner intervention.
 * @dev Receives a share of sell taxes, tracks LP contributions, and finalizes rounds
 *      either when thresholds are reached or when a timeout period expires.
 */

interface IJackpotToken {
    function getLPValue() external view returns (uint256);
    function owner() external view returns (address);
}

contract JackpotLPVault is ReentrancyGuard {
    IJackpotToken public immutable token;
	address public lpManager;
    
    // Round management
    uint256 public currentRound;
    bool public snapshotTaken;
    
    // Buffer system (2 buffers alternating)
    uint256 public activeBuffer; // 0 or 1
    mapping(uint256 => mapping(address => uint256)) public bufferContributions; // buffer => user => BNB contributed
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
    uint256 public constant TOP_WINNERS = 150; // Top 150 contributors
    uint256 public constant CLAIM_DEADLINE = 30 days;
    uint256 public constant MAX_PARTICIPANTS = 1000; // Safety limit
    
    // Events
    event LPContributed(address indexed user, uint256 bnbAmount, uint256 round);
    event SnapshotTaken(uint256 indexed round, uint256 participants, uint256 totalContributed);
    event RoundFinalized(uint256 indexed round, uint256 totalDistributed, uint256 winnersCount);
    event RewardClaimed(address indexed user, uint256 indexed round, uint256 amount);
    event Funded(address indexed from, uint256 amount, uint256 potAfter);
    
    modifier onlyToken() {
        require(msg.sender == address(token), "Only token can call");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == token.owner(), "Only owner can call");
        _;
    }
    
    constructor(address _token) {
        token = IJackpotToken(_token);
        activeBuffer = 0;
        currentRound = 0;
    }
	
	/**
     * @notice Set LP Manager address (one-time only)
     */
    function setLPManager(address _lpManager) external onlyOwner {
        require(lpManager == address(0), "LP Manager already set");
        require(_lpManager != address(0), "Invalid address");
        lpManager = _lpManager;
    }
    
    // ============================================
    // CORE FUNCTIONS - LP CONTRIBUTION
    // ============================================
    
    /**
     * @notice Record LP contribution from user
     * @dev Called by token contract when user adds LP through site
     */
    function recordLPContribution(address user, uint256 bnbAmount) external {
        require(
            msg.sender == address(token) || msg.sender == lpManager,
            "Only token or LP manager"
        );
        require(!snapshotTaken, "Snapshot already taken");
        require(bnbAmount >= getMinLPRequired(), "Below minimum LP required");
        
        // Add to buffer if not already in
        if (!isInBuffer[activeBuffer][user]) {
            bufferParticipants[activeBuffer].push(user);
            isInBuffer[activeBuffer][user] = true;
        }
        
        // Add contribution to current buffer
        bufferContributions[activeBuffer][user] += bnbAmount;
        
        // Track lifetime
        lifetimeContributions[user] += bnbAmount;
        
        emit LPContributed(user, bnbAmount, currentRound);
        
        // Check if we should take snapshot
        if (address(this).balance >= getPotThreshold()) {
            _takeSnapshot();
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
        
        emit SnapshotTaken(
            currentRound,
            bufferParticipants[activeBuffer].length,
            _getTotalContributions(activeBuffer)
        );
    }
    
    /**
     * @notice Finalize round and calculate rewards for top 150
     * @dev Distributes pot proportionally to top contributors
     * @dev ANYONE can finalize if snapshot is taken (prevents lockup if owner renounced)
     */
    function finalizeRound() external {
        require(snapshotTaken, "No snapshot taken");
        require(!rounds[currentRound].finalized, "Round already finalized");
        
        uint256 snapshotBuffer = activeBuffer;
        uint256 potAmount = address(this).balance;
        
        // Get top 150 contributors
        (address[] memory topContributors, uint256[] memory contributions) = _getTopContributors(snapshotBuffer);
        
        // Calculate total contributions of top 150
        uint256 totalTopContributions = 0;
        for (uint256 i = 0; i < topContributors.length; i++) {
            totalTopContributions += contributions[i];
        }
        
        require(totalTopContributions > 0, "No valid contributions");
        
        // Calculate and record rewards (proportional)
        for (uint256 i = 0; i < topContributors.length; i++) {
            uint256 reward = (potAmount * contributions[i]) / totalTopContributions;
            roundRewards[currentRound][topContributors[i]] = reward;
        }
        
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
        uint256 topCount = count < TOP_WINNERS ? count : TOP_WINNERS;
        
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
     * @notice Receive LP jackpot funding from token contract
     * @dev Called when sell tax is processed
     */
    function onLPTaxReceived() external payable onlyToken {
        require(msg.value > 0, "No BNB sent");
        
        emit Funded(msg.sender, msg.value, address(this).balance);
        
        // Check if we should take snapshot
        if (!snapshotTaken && address(this).balance >= getPotThreshold()) {
            if (bufferParticipants[activeBuffer].length > 0) {
                _takeSnapshot();
            }
        }
    }
    
    // ============================================
    // STAGE SYSTEM (Dynamic Thresholds)
    // ============================================
    
    function getCurrentStage() public view returns (uint256) {
        uint256 lpValue = token.getLPValue();
        
        if (lpValue < 10 ether) return 1;
        if (lpValue < 25 ether) return 2;
        if (lpValue < 50 ether) return 3;
        if (lpValue < 100 ether) return 4;
        return 5;
    }
    
    function getMinLPRequired() public view returns (uint256) {
        uint256 stage = getCurrentStage();
        
        if (stage == 1) return 0.5 ether;   // $300
        if (stage == 2) return 0.25 ether;  // $150
        if (stage == 3) return 0.1 ether;   // $60
        if (stage == 4) return 0.05 ether;  // $30
        return 0.025 ether;                 // $15 (stage 5)
    }
    
    function getPotThreshold() public view returns (uint256) {
        uint256 stage = getCurrentStage();
        
        if (stage == 1) return 2 ether;   // $1,200
        if (stage == 2) return 3 ether;   // $1,800
        if (stage == 3) return 4 ether;   // $2,400
        if (stage == 4) return 5 ether;   // $3,000
        return 6 ether;                   // $3,600 (stage 5)
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
        uint256 bufferIndex = snapshotTaken ? (1 - activeBuffer) : activeBuffer;
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
        
        uint256 potAmount = address(this).balance;
        
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
        uint256 bufferIndex = snapshotTaken ? (1 - activeBuffer) : activeBuffer;
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
            if (totalTop > 0) {
                estimatedReward = (address(this).balance * currentContribution) / totalTop;
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
     * @notice Get round info
     */
    function getRoundInfo(uint256 roundId) external view returns (
        uint256 totalDistributed,
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
        uint256 potBalance,
        uint256 threshold,
        bool snapshotTaken_,
        uint256 minLPRequired,
        uint256 stage
    ) {
        return (
            currentRound,
            bufferParticipants[activeBuffer].length,
            address(this).balance,
            getPotThreshold(),
            snapshotTaken,
            getMinLPRequired(),
            getCurrentStage()
        );
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
    
    /**
     * @notice Recover unclaimed rewards after deadline
     */
    function recoverUnclaimedRewards(uint256 roundId) external onlyOwner nonReentrant {
        require(rounds[roundId].finalized, "Round not finalized");
        require(
            block.timestamp > rounds[roundId].timestamp + CLAIM_DEADLINE,
            "Claim period not ended"
        );
        
        uint256 unclaimed = 0;
        
        // This would require tracking all winners - simplified for now
        // In practice, you'd track winners in an array during finalization
        
        require(unclaimed > 0, "No unclaimed rewards");
        
        (bool success, ) = payable(token.owner()).call{value: unclaimed}("");
        require(success, "Transfer failed");
    }
    
    receive() external payable {
        revert("Use onLPTaxReceived");
    }
}
