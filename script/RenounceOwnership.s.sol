// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IOwnable {
    function owner() external view returns (address);
    function renounceOwnership() external;
}

interface IJACKsPools {
    function tradingEnabled() external view returns (bool);
    function vaultLocked() external view returns (bool);
}

interface IJACKsVault {
    function emergencyPause() external view returns (bool);
}

contract RenounceOwnership is Script {
    // Base Sepolia addresses
    address constant TOKEN = 0xfEA677CA47b1EDD9508D2D943aa716b39dD37D7b;
    address constant VAULT = 0x39cb5b7086B824Afb907c10904c7c935e9E74e41;
    address constant LPVAULT = 0x84458eA7d67CF920D002D96a10F4ECb778AF3119;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== OWNERSHIP RENOUNCE SCRIPT ===");
        console.log("Deployer:", deployer);
        console.log("");
        
        // Check current state
        console.log("Current Ownership:");
        address tokenOwner = IOwnable(TOKEN).owner();
        address vaultOwner = IOwnable(VAULT).owner();
        console.log("TOKEN owner:", tokenOwner);
        console.log("VAULT owner:", vaultOwner);
        console.log("");
        
        // Verify preconditions for TOKEN
        bool tradingEnabled = IJACKsPools(TOKEN).tradingEnabled();
        bool vaultLocked = IJACKsPools(TOKEN).vaultLocked();
        console.log("TOKEN tradingEnabled:", tradingEnabled);
        console.log("TOKEN vaultLocked:", vaultLocked);
        console.log("");
        
        require(tradingEnabled, "Trading must be enabled first");
        require(vaultLocked, "Vault must be locked first");
        require(tokenOwner == deployer, "Deployer is not TOKEN owner");
        require(vaultOwner == deployer, "Deployer is not VAULT owner");
		
		// CRITICAL: vault paused = permanent lockout after renounce
        bool vaultPaused = IJACKsVault(VAULT).emergencyPause();
        console.log("VAULT emergencyPause:", vaultPaused);
        require(!vaultPaused, "VAULT is paused - unpause before renounce");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Renounce VAULT ownership first (no dependencies)
        console.log("Step 1: Renouncing VAULT ownership...");
        IOwnable(VAULT).renounceOwnership();
        console.log("VAULT ownership renounced!");
        
        // 2. Renounce TOKEN ownership (this also affects LP_VAULT)
        console.log("Step 2: Renouncing TOKEN ownership...");
        IOwnable(TOKEN).renounceOwnership();
        console.log("TOKEN ownership renounced!");
        console.log("Note: LP_VAULT now has no owner (uses TOKEN.owner())");
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== OWNERSHIP RENOUNCED SUCCESSFULLY ===");
        console.log("New owners (should be 0x0000...):");
        console.log("TOKEN owner:", IOwnable(TOKEN).owner());
        console.log("VAULT owner:", IOwnable(VAULT).owner());
        console.log("");
        console.log("All contracts are now AUTONOMOUS!");
        console.log("No admin control remains.");
    }
}
