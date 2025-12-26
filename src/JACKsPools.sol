// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title JACKs Pools 
 * @notice Community reward distribution system on Base L2.
 * @notice JACKs Pools: Automated on-chain reward mechanics with transparent distribution.
 * @notice Participation is voluntary; the contract operates autonomously without external control.
 * @dev Implements buy tax, auto-liquidity, sell lock, and reward pool funding logic.
 */
 
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function sync() external;
}

interface IJACKsVault {
    function onTaxReceived() external payable; 
    function addEligibleBuyer(address buyer, uint256 ethAmount) external;
}

interface IJACKsLPVault {
    function onLpTaxReceived() external payable; 
    function recordLpContribution(address user, uint256 ethAmount) external;
}

contract JACKsPools is IERC20, ReentrancyGuard {
    // Balances and allowances
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) public sellUnlock; // Sell lock timestamp
	mapping(address => uint256) public lastBuyTime; // Buy cooldown timestamp
    mapping(address => bool) public isExempt; // Tax and lock exemptions
    
    // Token metadata
    string public constant NAME = "JACKs Pools";
    string public constant SYMBOL = "JACK";
    uint8 public constant DECIMALS = 18;
    uint256 public constant totalSupply = 1_100_000_000 * 10**18; // 1.1B
    
    // Tax configuration (immutable)
	uint256 public constant BUY_TAX_REWARD_BPS = 775;  // 7.75%
	uint256 public constant BUY_TAX_LP_BPS = 200;       // 2%
	uint256 public constant BUY_TAX_BURN_BPS = 25;      // 0.25%
	uint256 public constant TOTAL_BUY_TAX_BPS = 1000;   // 10% total
	uint256 public constant SELL_TAX_LP_BPS = 1000;     // 10%
	uint256 public constant BPS = 10000;
	uint256 public constant SELL_LOCK_DURATION = 2 hours;
	uint256 public constant BUY_COOLDOWN = 30; // 30 seconds between buys
	uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10% max slippage
	uint256 public constant MAX_WALLET_LP_THRESHOLD = 50 ether; // 50 ETH LP value to remove limit
    
    // Contracts
    IUniswapV2Router02 public immutable ROUTER;
    address public immutable PAIR;
    address public immutable WETH;
    IJACKsVault public VAULT;
	IJACKsLPVault public LP_VAULT;
	address public LP_MANAGER; // Contract that handles LP additions
    
    // Swap configuration
    uint256 public minSwapTokens = 1000 * 10**18; // 1000 tokens minimum (for low LP launches)
    uint256 private _rewardTokens;
	uint256 private _lpTokens;
	uint256 private _lpRewardTokens;
	uint256 public lastProcessBlock;
    
    // State
    bool private _swapping;
	bool public vaultLocked;
    bool public tradingEnabled;
    address public owner;
    
    // Constants
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
	address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;
	
	// Stage thresholds for dynamic parameters
	uint256 private constant STAGE_2_LP_THRESHOLD = 2 ether;
	uint256 private constant STAGE_3_LP_THRESHOLD = 5 ether;
	uint256 private constant STAGE_4_LP_THRESHOLD = 10 ether;
	uint256 private constant STAGE_5_LP_THRESHOLD = 20 ether;

	// Stage 1 parameters (LP < 2 ETH)
	uint256 private constant STAGE_1_MIN_BUY = 0.00043 ether;
	uint256 private constant STAGE_1_MAX_WALLET = 15_000_000 * 10**18;

	// Stage 2 parameters (LP 2-5 ETH)
	uint256 private constant STAGE_2_MIN_BUY = 0.00057 ether;
	uint256 private constant STAGE_2_MAX_WALLET = 30_000_000 * 10**18;

	// Stage 3 parameters (LP 5-10 ETH)
	uint256 private constant STAGE_3_MIN_BUY = 0.00071 ether;
	uint256 private constant STAGE_3_MAX_WALLET = 60_000_000 * 10**18;

	// Stage 4 parameters (LP 10-20 ETH)
	uint256 private constant STAGE_4_MIN_BUY = 0.00086 ether;
	uint256 private constant STAGE_4_MAX_WALLET = 90_000_000 * 10**18;

	// Stage 5 parameters (LP > 20 ETH)
	uint256 private constant STAGE_5_MIN_BUY = 0.001 ether;
    
    // Events
    event OwnershipRenounced();
    event VaultSet(address indexed vault);
	event LpVaultSet(address indexed lpVault);
	event LpManagerSet(address indexed lpManager);
    event TradingEnabled();
    event TaxProcessed(uint256 rewardEth, uint256 lpEth, uint256 burnedTokens);
    event TaxProcessingFailed(uint256 rewardTokens, uint256 lpTokens, uint256 lpRewardTokens, string reason);
	event SellLockSet(address indexed account, uint256 unlockTime);
    event AutoLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 liquidity);
    event MinSwapTokensUpdated(uint256 oldValue, uint256 newValue);
	        
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier lockSwap() {
        _swapping = true;
        _;
        _swapping = false;
    }
    
    constructor(address _router) {
        require(_router != address(0), "Zero router");
        
        owner = msg.sender;
		ROUTER = IUniswapV2Router02(_router);
		WETH = ROUTER.WETH();

		// Validate Base deployment
		require(WETH == BASE_WETH, "Not Base");
        
        // Create pair
        PAIR = IUniswapV2Factory(ROUTER.factory()).createPair(address(this), WETH);
        require(PAIR != address(0), "Pair creation failed");
        
        // Setup exemptions
        isExempt[msg.sender] = true;
        isExempt[address(this)] = true;
        isExempt[DEAD] = true;
        
        // Mint supply
        _balances[msg.sender] = 100_000_000 * 10**18; // 100M to deployer
        _balances[address(this)] = 1_000_000_000 * 10**18; // 1B for liquidity
        
        emit Transfer(address(0), msg.sender, 100_000_000 * 10**18);
        emit Transfer(address(0), address(this), 1_000_000_000 * 10**18);
    }
    
    // One-time vault setter
    function setVault(address _vault) external onlyOwner {
        require(!vaultLocked, "Vault locked");
        require(_vault != address(0), "Zero vault");
        
        VAULT = IJACKsVault(_vault);
        vaultLocked = true;
		isExempt[_vault] = true;
        
        emit VaultSet(_vault);
    }
    
	/**
	 * @notice Set LP Vault address (one-time only, before buyer vault)
	 * @param _lpVault Address of LP reward vault
	 */
	function setLpVault(address _lpVault) external onlyOwner {
		require(!vaultLocked, "Set LP Vault before Buyer Vault"); 
		require(address(LP_VAULT) == address(0), "LP Vault already set");
		require(_lpVault != address(0), "Invalid address");
		LP_VAULT = IJACKsLPVault(_lpVault);	
		emit LpVaultSet(_lpVault);
	}

	/**
	 * @notice Set LP Manager address (one-time only, before buyer vault)
	 * @param _lpManager Address of LP manager contract
	 */
	function setLpManager(address _lpManager) external onlyOwner {
		require(!vaultLocked, "Set LP Manager before Buyer Vault");
		require(LP_MANAGER == address(0), "LP Manager already set");
		require(_lpManager != address(0), "Invalid address");
		LP_MANAGER = _lpManager;
		isExempt[_lpManager] = true;
		emit LpManagerSet(_lpManager);
	}
	
    // Enable trading after liquidity added
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        require(vaultLocked, "Set vault first");
        tradingEnabled = true;
        emit TradingEnabled();
    }
    
    // Update minimum swap threshold
    function updateMinSwapTokens(uint256 _minSwapTokens) external onlyOwner {
        require(_minSwapTokens >= 100 * 10**18, "Too low"); // Min 100 tokens
        require(_minSwapTokens <= 100_000 * 10**18, "Too high"); // Max 100k tokens
        uint256 old = minSwapTokens;
        minSwapTokens = _minSwapTokens;
        emit MinSwapTokensUpdated(old, _minSwapTokens);
    }
    
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address recipient, uint256 amount) public override returns (bool) {
		_transfer(msg.sender, recipient, amount, false);
		return true;
	}
    
    function allowance(address tokenOwner, address spender) public view override returns (uint256) {
		return _allowances[tokenOwner][spender];
	}
    
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
		uint256 currentAllowance = _allowances[sender][msg.sender];
		require(currentAllowance >= amount, "Exceeds allowance");
		
		// Determine if LP addition (local variable, not state!)
		bool isLpAddition = (msg.sender == LP_MANAGER && recipient == PAIR);
		
		// EFFECTS - UPDATE ALLOWANCE FIRST (BEFORE EXTERNAL CALLS!)
		if (currentAllowance != type(uint256).max) {
			_approve(sender, msg.sender, currentAllowance - amount);
		}

		// INTERACTIONS - EXTERNAL CALL AFTER STATE UPDATE!
		_transfer(sender, recipient, amount, isLpAddition);
		
		return true;
	}
    
    function _approve(address tokenOwner, address spender, uint256 amount) private {
		require(tokenOwner != address(0), "From zero");
		require(spender != address(0), "To zero");
		
		_allowances[tokenOwner][spender] = amount;
		emit Approval(tokenOwner, spender, amount);
	}
    
    function _transfer(address from, address to, uint256 amount, bool isLpAddition) private {
        require(from != address(0), "From zero");
        require(to != address(0), "To zero");
        require(amount > 0, "Zero amount");
        require(_balances[from] >= amount, "Insufficient balance");
        
        // Check trading status
        if (!tradingEnabled) {
            require(isExempt[from] || isExempt[to], "Trading not enabled");
        }
       
	   // Determine transaction type
		bool isBuy = from == PAIR;
		bool isSell = to == PAIR && from != address(this) && !isLpAddition;
		
		// Block unauthorized liquidity pools (ONLY official PAIR allowed)
		if (!isExempt[from] && !isExempt[to]) {
			// Check if 'from' is an unauthorized pair
			if (from != PAIR && _isPair(from)) {
				revert("Unauthorized liquidity pool - use official pool only");
			}
			
			// Check if 'to' is an unauthorized pair
			if (to != PAIR && _isPair(to)) {
				revert("Unauthorized liquidity pool - use official pool only");
			}
		}

		// Check sell lock FIRST (independent of tax exemptions)
		// Exception: LP additions by Router/LPManager bypass sell lock
		if (isSell && !isExempt[from] && !isLpAddition) {
			require(block.timestamp >= sellUnlock[from], "Sell locked 2h");
		}
        
		// Propagate sell lock on transfers (not to pair/router/exempt)
        if (from != PAIR && to != PAIR && !isExempt[to] && !isExempt[from]) {
            if (sellUnlock[from] > sellUnlock[to]) {
                sellUnlock[to] = sellUnlock[from];
                emit SellLockSet(to, sellUnlock[to]);
            }
        }
        
        bool takeTax = !_swapping && 
               !isLpAddition &&  
               !isExempt[from] && 
               !isExempt[to] && 
               !isExempt[msg.sender] && 
               tradingEnabled;
        uint256 taxAmount = 0;
		uint256 contractTax = 0;
        
        // Buy tax
		if (takeTax && isBuy) {
			// Buy cooldown check (anti-spam)
			require(
				block.timestamp >= lastBuyTime[to] + BUY_COOLDOWN,
				"Wait 30s between buys"
			);
			lastBuyTime[to] = block.timestamp;
			
			taxAmount = (amount * TOTAL_BUY_TAX_BPS) / BPS;
			
			// Split tax components
			uint256 rewardTokens = (amount * BUY_TAX_REWARD_BPS) / BPS;
			uint256 lpTokens = (amount * BUY_TAX_LP_BPS) / BPS;
			uint256 burnTokens = (amount * BUY_TAX_BURN_BPS) / BPS;
			
			// Burn immediately
			if (burnTokens > 0) {
				_balances[DEAD] += burnTokens;
				emit Transfer(from, DEAD, burnTokens);
			}
			
			// Contract gets only reward + lp (NOT burn!)
			contractTax = taxAmount - burnTokens;
			
			_rewardTokens += rewardTokens;
			_lpTokens += lpTokens;
									
			// Set sell lock for buyer
			sellUnlock[to] = block.timestamp + SELL_LOCK_DURATION;
			emit SellLockSet(to, sellUnlock[to]);
		}
        
		// Sell tax - Split 50/50 (LP Reward + Auto LP)
		if (takeTax && isSell) {
			taxAmount = (amount * SELL_TAX_LP_BPS) / BPS;
			contractTax = taxAmount;
			
			uint256 halfTax = taxAmount / 2;
			
			// 50% to LP Reward
			_lpRewardTokens += halfTax;
			
			// 50% to Auto LP
			_lpTokens += (taxAmount - halfTax); // Remaining goes to LP (handles odd amounts)
		}

        // Execute transfer
        if (taxAmount > 0) {
            _balances[address(this)] += contractTax;
            emit Transfer(from, address(this), contractTax);
        }

        // EFFECTS - UPDATE BALANCES & EMIT EVENTS (BEFORE EXTERNAL CALLS!)
              
        _balances[from] -= amount;
        _balances[to] += (amount - taxAmount);
        
        emit Transfer(from, to, amount - taxAmount);
        
        // Check max wallet limit AFTER balance is updated (still part of Effects)
        // Skip for: sells, exempt addresses, pair, and contract itself
        if (!isSell && !isExempt[to] && to != PAIR && to != address(this)) {
            uint256 maxWallet = getMaxWalletTokens();
            
            // If max is type(uint256).max, no limit applies
            if (maxWallet < type(uint256).max) {
                require(
                    _balances[to] <= maxWallet,
                    "Exceeds max wallet limit"
                );
            }
        }
		
        // INTERACTIONS - EXTERNAL CALLS (AFTER ALL STATE UPDATES!)
        
        // Process accumulated taxes (AUTO + MANUAL)
        // Simple condition: just check if we have enough tokens
        if (
            !_swapping &&
            isBuy &&
            !isLpAddition &&
            _balances[address(this)] >= minSwapTokens &&
            vaultLocked &&
			block.number > lastProcessBlock
        ) {
			// Try to process (fails silent if issues)
            lastProcessBlock = block.number;
			try this.processTaxesInternal() {} catch {}
        }
        
        // Add buyer to eligible pool (after balance is confirmed updated)
		if (isBuy && vaultLocked && address(VAULT) != address(0)) {
			uint256 ethValue = _getEthValue(amount - taxAmount);
			try VAULT.addEligibleBuyer(to, ethValue) {} catch {}
		}
    }
    
    function _processTaxes() private lockSwap {

		// Save to locals first
		uint256 localReward = _rewardTokens;
		uint256 localLp = _lpTokens;
		uint256 localLpReward = _lpRewardTokens;
		
		uint256 tokensToProcess = localReward + localLp + localLpReward;
		if (tokensToProcess == 0) return;
		
		// Use available contract balance
		uint256 contractBalance = _balances[address(this)];

		// Adjust locals proportionally if insufficient balance
		if (tokensToProcess > contractBalance) {
			uint256 adjustmentRatio = (contractBalance * BPS) / tokensToProcess;
			localReward = (localReward * adjustmentRatio) / BPS;
			localLp = (localLp * adjustmentRatio) / BPS;
			localLpReward = (localLpReward * adjustmentRatio) / BPS;
			tokensToProcess = contractBalance;
		}
		
		if (tokensToProcess == 0) return;
		
		// EXPLICIT swap composition
		uint256 totalTokens = localReward + localLp + localLpReward;
		uint256 lpHalf = (localLp * tokensToProcess) / totalTokens / 2;
		
		// What actually gets swapped to ETH
		uint256 swapReward = (localReward * tokensToProcess) / totalTokens;
		uint256 swapLpReward = (localLpReward * tokensToProcess) / totalTokens;
		uint256 swapLpPart = ((localLp * tokensToProcess) / totalTokens) - lpHalf;
		uint256 tokensToSwap = swapReward + swapLpReward + swapLpPart;
				
		if (tokensToSwap > 0) {
			uint256 initialBalance = address(this).balance;
			
			// Calculate minimum output with slippage protection (CAN REVERT)
			uint256 minOutput = _calculateMinOutput(tokensToSwap);
			
			address[] memory path = new address[](2);
			path[0] = address(this);
			path[1] = WETH;
			
			// Approve router for swap + LP in one call (CAN REVERT, CEI pattern)
			uint256 approveAmount = lpHalf > 0 ? tokensToSwap + lpHalf : tokensToSwap;
			_approve(address(this), address(ROUTER), approveAmount);
			
			// Reset Storage
			_rewardTokens = 0;
			_lpTokens = 0;
			_lpRewardTokens = 0;
			
			try ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
				tokensToSwap,
				minOutput,
				path,
				address(this),
				block.timestamp
			) {
				uint256 ethReceived = address(this).balance - initialBalance;

				if (ethReceived > 0) {
					// Calculate proportional split (safe from underflow)
					uint256 ethForReward = (ethReceived * swapReward) / tokensToSwap;
					uint256 ethForLpReward = (ethReceived * swapLpReward) / tokensToSwap;
					
					// Use REMAINDER for ethForLp (prevents underflow from rounding)
					uint256 allocated = ethForReward + ethForLpReward;
					uint256 ethForLp = ethReceived > allocated ? ethReceived - allocated : 0;

					// Send to buyer reward round
					if (ethForReward > 0 && address(VAULT) != address(0)) {
						try VAULT.onTaxReceived{value: ethForReward}() {} catch {}
					}

					// Send to LP reward round
					if (ethForLpReward > 0 && address(LP_VAULT) != address(0)) {
						try LP_VAULT.onLpTaxReceived{value: ethForLpReward}() {} catch {}
					}

					// Add liquidity
					if (ethForLp > 0 && lpHalf > 0) {
						try ROUTER.addLiquidityETH{value: ethForLp}(
							address(this),
							lpHalf,
							0,
							0,
							DEAD,
							block.timestamp
						) returns (uint256 tokenUsed, uint256 ethUsed, uint256 liquidity) {
							emit AutoLiquify(tokenUsed, ethUsed, liquidity);
						} catch {}
					}

					emit TaxProcessed(ethForReward + ethForLpReward, ethForLp, 0);
				}
			} catch {
								
				// Emit for monitoring/debugging
				emit TaxProcessingFailed(localReward, localLp, localLpReward, "Swap failed");
			}
		}       
	}
    
    function _calculateMinOutput(uint256 tokenAmount) private view returns (uint256) {
		if (tokenAmount == 0) return 0;
		
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = WETH;
		
		try ROUTER.getAmountsOut(tokenAmount, path) returns (uint[] memory amounts) {
			if (amounts.length >= 2 && amounts[1] > 0) {
				// Apply slippage protection (90% minimum)
				return (amounts[1] * (BPS - MAX_SLIPPAGE_BPS)) / BPS;
			}
		} catch {}
		
		return 0; // Fallback to 0 if calculation fails
	}
    
    function getLpValue() public view returns (uint256) {
		try IUniswapV2Pair(PAIR).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
			// Validate reserves are not zero
			if (reserve0 == 0 && reserve1 == 0) {
				return 0; // Before initial liquidity → strictest max wallet (but trading disabled anyway)
			}
			
			address token0 = IUniswapV2Pair(PAIR).token0();
			uint256 ethReserve = token0 == WETH ? reserve0 : reserve1;

			// Validate ETH reserve
			if (ethReserve == 0) {
				return 0; // Edge case: token reserve exists but no ETH → strictest max wallet
			}

			return ethReserve * 2; // Total LP value = 2x ETH reserve
		} catch {
			// Return high value to DISABLE max wallet limit on error
			// This is safer than returning 0 which activates strictest limit
			return 100 ether; // Returns Stage 5 threshold → no max wallet limit
		}
	}
	
	/**
	 * @notice Calculate ETH value of token amount
	 * @param tokenAmount Amount of tokens to evaluate
	 * @return ETH value in wei
	 */
	function _getEthValue(uint256 tokenAmount) internal view returns (uint256) {
		if (tokenAmount == 0) return 0;
		
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = WETH;
		
		try ROUTER.getAmountsOut(tokenAmount, path) returns (uint[] memory amounts) {
			if (amounts.length >= 2 && amounts[1] > 0) {
				return amounts[1]; // ETH value in wei
			}
		} catch {}
		
		return 0; // Fallback safe
	}
	
	/**
	 * @notice Get current minimum buy requirement based on LP value
	 */
	function getMinBuyForLastBuyer() public view returns (uint256) {
		uint256 lpValue = getLpValue();
		
		if (lpValue < STAGE_2_LP_THRESHOLD) {
			return STAGE_1_MIN_BUY;
		}
		
		if (lpValue < STAGE_3_LP_THRESHOLD) {
			return STAGE_2_MIN_BUY;
		}
		
		if (lpValue < STAGE_4_LP_THRESHOLD) {
			return STAGE_3_MIN_BUY;
		}
		
		if (lpValue < STAGE_5_LP_THRESHOLD) {
			return STAGE_4_MIN_BUY;
		}
		
		return STAGE_5_MIN_BUY;
	}
    
	/**
	 * @notice Get maximum wallet tokens based on LP value (dynamic scaling)
	 * @dev Top-tier thresholds for serious project growth
	 */
	function getMaxWalletTokens() public view returns (uint256) {
		uint256 lpValue = getLpValue();
		
		if (lpValue < STAGE_2_LP_THRESHOLD) {
			return STAGE_1_MAX_WALLET;
		} else if (lpValue < STAGE_3_LP_THRESHOLD) {
			return STAGE_2_MAX_WALLET;
		} else if (lpValue < STAGE_4_LP_THRESHOLD) {
			return STAGE_3_MAX_WALLET;
		} else if (lpValue < STAGE_5_LP_THRESHOLD) {
			return STAGE_4_MAX_WALLET;
		} else {
			return type(uint256).max; // No limit Stage 5
		}
	}
	
	/**
	 * @notice Check if address is a Uniswap V2 pair contract
	 * @dev Works with any Uniswap V2 fork
	 */
	function _isPair(address account) private view returns (bool) {
		if (account.code.length == 0) return false; // Not a contract
		
		try IUniswapV2Pair(account).token0() returns (address) {
			return true; // Has token0() = is a liquidity pair
		} catch {
			return false; // Not a pair
		}
	}
	
    // Add initial liquidity
    function addInitialLiquidity() external payable onlyOwner {
        require(msg.value > 0, "Need ETH");
        require(!tradingEnabled, "Trading already enabled");
        
        uint256 tokenAmount = _balances[address(this)];
        require(tokenAmount > 0, "No tokens");
        
        _approve(address(this), address(ROUTER), tokenAmount);
        
        ROUTER.addLiquidityETH{value: msg.value}(
            address(this),
            tokenAmount,
            0,
            0,
            DEAD, // Burn initial LP
            block.timestamp
        );
    }
    
    // Emergency function to process stuck taxes (owner only, before renounce)
	function emergencyProcessTaxes() external onlyOwner {
		require(!_swapping, "Already processing");
		if (_rewardTokens + _lpTokens > 0) {
			_processTaxes();
		}
		// Silent success if nothing to process
	}
    
    // Renounce ownership
    function renounceOwnership() external onlyOwner {
        require(tradingEnabled, "Enable trading first");
        require(vaultLocked, "Set vault first");
        owner = address(0);
        emit OwnershipRenounced();
    }
    
    // Recovery function for stuck ETH (owner only, before renounce)
    function recoverEth() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH");
        (bool success,) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }
    
    // Check if max wallet limit is active
    function isMaxWalletActive() public view returns (bool) {
		return getMaxWalletTokens() < type(uint256).max;
	}
        
	// Get current max wallet limit (dynamic based on LP)
	function getMaxWalletLimit() public view returns (uint256) {
		return getMaxWalletTokens();
	}
    
    // Get LP threshold for removing max wallet
    function getMaxWalletLpThreshold() public pure returns (uint256) {
        return MAX_WALLET_LP_THRESHOLD;
    }
	
	/**
     * @notice Process accumulated taxes manually (anyone can call)
     * @dev Caller receives 0.3% reward from generated ETH
     */
    function processTaxes() external nonReentrant {
        require(_balances[address(this)] >= minSwapTokens, "Not enough tokens");
        _processTaxesWithReward(msg.sender);
    }
    
    /**
     * @notice Internal processing (auto-triggered from _transfer)
     */
    function processTaxesInternal() external {
        require(msg.sender == address(this), "Only self");
        _processTaxes();
    }
    
    /**
     * @notice Process taxes with optional caller reward
     */
    function _processTaxesWithReward(address caller) private lockSwap {
        uint256 ethBefore = address(this).balance;

		_processTaxes();

		// Reward caller with 0.3% of generated ETH (not for auto-calls)
		if (caller != address(this) && caller != address(0)) {
			uint256 ethGenerated = address(this).balance - ethBefore;
			uint256 reward = (ethGenerated * 30) / 10000; // 0.3%
            
            if (reward > 0) {
                (bool success,) = caller.call{value: reward}("");
                require(success, "Reward failed");
            }
        }
    }
    
    receive() external payable {
    // Only accept ETH from Router (LP operations) or Vaults (should never happen)
    require(
        msg.sender == address(ROUTER) || 
        msg.sender == address(VAULT) || 
        msg.sender == address(LP_VAULT),
        "No direct ETH - use swap/LP functions"
    );
	}
}