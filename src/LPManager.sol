// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LPManager - Liquidity Management Gateway
 * @notice Coordinates LP additions and records contributions for the LP Jackpot system.
 * @notice Operates as the on-chain bridge between users, the PancakeSwap router, and the LPVault.
 * @dev Users add LP through this contract (via frontend) to become eligible for LP Jackpot rounds.
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IJackpotToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IJackpotLPVault {
    function recordLPContribution(address user, uint256 bnbAmount) external;
}

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract LPManager is ReentrancyGuard {
    IJackpotToken public immutable token;
    IJackpotLPVault public immutable lpVault;
    IUniswapV2Router02 public immutable router;
    
    event LPAdded(
        address indexed user,
        uint256 tokenAmount,
        uint256 bnbAmount,
        uint256 liquidity,
        bool recordedInJackpot
    );
    
    constructor(
        address _token,
        address _lpVault,
        address _router
    ) {
        token = IJackpotToken(_token);
        lpVault = IJackpotLPVault(_lpVault);
        router = IUniswapV2Router02(_router);
    }
    
    /**
     * @notice Add liquidity and register for LP Jackpot
     * @dev User must approve tokens to this contract first
     * @param tokenAmount Amount of tokens to add
     * @param tokenMin Minimum tokens (slippage protection)
     * @param bnbMin Minimum BNB (slippage protection)
     * @param deadline Transaction deadline
     */
    function addLiquidityAndRegister(
        uint256 tokenAmount,
        uint256 tokenMin,
        uint256 bnbMin,
        uint256 deadline
    ) external payable nonReentrant returns (
        uint256 addedTokens,
        uint256 addedBNB,
        uint256 liquidity
    ) {
        require(msg.value > 0, "No BNB sent");
        require(tokenAmount > 0, "No tokens specified");
        
        // Transfer tokens from user to this contract
        require(
            token.transferFrom(msg.sender, address(this), tokenAmount),
            "Token transfer failed"
        );
        
        // Approve router to spend tokens
        require(
            token.approve(address(router), tokenAmount),
            "Approval failed"
        );
        
        // Add liquidity (LP tokens go to user)
        (addedTokens, addedBNB, liquidity) = router.addLiquidityETH{value: msg.value}(
            address(token),
            tokenAmount,
            tokenMin,
            bnbMin,
            msg.sender,  // LP tokens go directly to user
            deadline
        );
        
        // Refund excess tokens if any
        uint256 excessTokens = tokenAmount - addedTokens;
        if (excessTokens > 0) {
            require(
                IERC20(address(token)).transfer(msg.sender, excessTokens),
                "Refund failed"
            );
        }
        
        // Refund excess BNB if any
        uint256 excessBNB = msg.value - addedBNB;
        if (excessBNB > 0) {
            (bool success, ) = payable(msg.sender).call{value: excessBNB}("");
            require(success, "BNB refund failed");
        }
        
        // Record contribution in LP Vault (if meets minimum)
        bool recorded = false;
        try lpVault.recordLPContribution(msg.sender, addedBNB) {
            recorded = true;
        } catch {
            // User doesn't meet minimum or buffer full - silently continue
            // They still get LP tokens, just not registered for jackpot
        }
        
        emit LPAdded(msg.sender, addedTokens, addedBNB, liquidity, recorded);
        
        return (addedTokens, addedBNB, liquidity);
    }
        
    receive() external payable {
		// Accept BNB refund from Router during LP addition
		// Reject direct BNB deposits from users
		require(
			msg.sender == address(router),
			"Use addLiquidityAndRegister"
		);
	}

}
