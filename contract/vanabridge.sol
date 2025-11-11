// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract VanaBridge is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20Metadata;
    
    IERC20Metadata public constant VANS_TOKEN = IERC20Metadata(0x82741ff5937933244eb562A4b396f8079F1de914);
    
    address public zeroGBridge;
    uint256 public bridgeFee = 0.001 ether;
    uint256 public minBridgeAmount = 1 ether;
    uint256 public maxBridgeAmount = 100000 ether;
    uint256 public totalLocked;
    
    mapping(bytes32 => bool) public usedProofs;
    
    event BridgedToZeroG(address indexed user, uint256 amount, bytes32 proofHash);
    event BridgedFromZeroG(address indexed user, uint256 amount, bytes32 proofHash);

    // ✅ TAMBAHKAN Ownable(msg.sender) SEPERTI DI ZeroGBridge
    constructor() Ownable(msg.sender) {
        require(verifyVANSToken(), "Invalid VANS token at deployment");
    }

    function verifyVANSToken() public view returns (bool) {
        try VANS_TOKEN.name() returns (string memory name) {
            if (keccak256(bytes(name)) != keccak256(bytes("vanaswap token"))) return false;
        } catch { return false; }
        
        try VANS_TOKEN.symbol() returns (string memory symbol) {
            if (keccak256(bytes(symbol)) != keccak256(bytes("VANS"))) return false;
        } catch { return false; }
        
        try VANS_TOKEN.decimals() returns (uint8 decimals) {
            if (decimals != 18) return false;
        } catch { return false; }
        
        return true;
    }

    function bridgeToZeroG(uint256 amount) external payable nonReentrant whenNotPaused returns (bytes32) {
        require(amount >= minBridgeAmount && amount <= maxBridgeAmount, "Invalid amount");
        require(msg.value >= bridgeFee, "Insufficient fee");
        require(verifyVANSToken(), "Invalid VANS token");
        
        uint256 balanceBefore = VANS_TOKEN.balanceOf(address(this));
        VANS_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = VANS_TOKEN.balanceOf(address(this));
        require(balanceAfter - balanceBefore == amount, "Token transfer failed");
        
        totalLocked += amount;
        
        bytes32 proofHash = keccak256(abi.encodePacked(
            msg.sender, amount, block.chainid, block.timestamp, "VANA_TO_ZEROG"
        ));
        
        require(!usedProofs[proofHash], "Proof collision");
        usedProofs[proofHash] = true;
        
        emit BridgedToZeroG(msg.sender, amount, proofHash);
        return proofHash;
    }

    function bridgeFromZeroG(bytes32 burnProof, uint256 amount, address recipient) external nonReentrant whenNotPaused {
        require(msg.sender == zeroGBridge, "Only 0G bridge");
        require(!usedProofs[burnProof], "Proof already used");
        require(amount <= totalLocked, "Insufficient liquidity");
        
        usedProofs[burnProof] = true;
        totalLocked -= amount;
        VANS_TOKEN.safeTransfer(recipient, amount);
        
        emit BridgedFromZeroG(recipient, amount, burnProof);
    }

    function setZeroGBridge(address _zeroGBridge) external onlyOwner {
        require(zeroGBridge == address(0), "Bridge already set");
        zeroGBridge = _zeroGBridge;
    }

    function setBridgeFee(uint256 newFee) external onlyOwner {
        bridgeFee = newFee;
    }

    function setBridgeLimits(uint256 min, uint256 max) external onlyOwner {
        require(min < max, "Invalid limits");
        minBridgeAmount = min;
        maxBridgeAmount = max;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdrawVANS(uint256 amount) external onlyOwner {
        require(paused(), "Only when paused");
        VANS_TOKEN.safeTransfer(owner(), amount);
        totalLocked -= amount;
    }

    receive() external payable {}
}