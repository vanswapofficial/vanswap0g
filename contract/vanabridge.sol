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
    
    // ✅ GUNAKAN IERC20Metadata UNTUK ACCESS name(), symbol(), decimals()
    IERC20Metadata public constant VANS_TOKEN = IERC20Metadata(0x82741ff5937933244eb562A4b396f8079F1de914);
    
    address public zeroGBridge;
    uint256 public bridgeFee = 0.001 ether;
    uint256 public minBridgeAmount = 1 ether;
    uint256 public maxBridgeAmount = 100000 ether;
    uint256 public totalLocked;
    
    mapping(bytes32 => bool) public usedProofs;
    mapping(address => uint256) public userDailyBridge;
    mapping(address => uint256) public lastBridgeTime;
    
    uint256 public constant DAILY_LIMIT = 10000 ether;
    
    event BridgedToZeroG(address indexed user, uint256 amount, bytes32 proofHash);
    event BridgedFromZeroG(address indexed user, uint256 amount, bytes32 proofHash);

    // ✅ TAMBAHKAN CONSTRUCTOR DENGAN initialOwner
    constructor(address initialOwner) Ownable(initialOwner) {
        // ✅ VERIFIKASI VANS TOKEN SAAT DEPLOY
        require(verifyVANSToken(), "Invalid VANS token at deployment");
    }

    // ✅ VERIFIKASI VANS TOKEN ASLI - NAME: "vanaswap token", SYMBOL: "VANS"
    function verifyVANSToken() public view returns (bool) {
        try VANS_TOKEN.name() returns (string memory name) {
            // ✅ NAME = "vanaswap token"
            if (keccak256(bytes(name)) != keccak256(bytes("vanaswap token"))) {
                return false;
            }
        } catch {
            return false;
        }
        
        try VANS_TOKEN.symbol() returns (string memory symbol) {
            // ✅ SYMBOL = "VANS"  
            if (keccak256(bytes(symbol)) != keccak256(bytes("VANS"))) {
                return false;
            }
        } catch {
            return false;
        }
        
        try VANS_TOKEN.decimals() returns (uint8 decimals) {
            // ✅ DECIMALS = 18
            if (decimals != 18) return false;
        } catch {
            return false;
        }
        
        return true;
    }

    // ✅ BRIDGE VANS → wVANS (HANYA VANS ASLI)
    function bridgeToZeroG(uint256 amount) external payable nonReentrant whenNotPaused returns (bytes32) {
        require(amount >= minBridgeAmount && amount <= maxBridgeAmount, "Invalid amount");
        require(msg.value >= bridgeFee, "Insufficient fee");
        require(verifyVANSToken(), "Invalid VANS token");
        
        // ✅ DAILY LIMIT CHECK
        if (block.timestamp - lastBridgeTime[msg.sender] > 1 days) {
            userDailyBridge[msg.sender] = 0;
        }
        require(userDailyBridge[msg.sender] + amount <= DAILY_LIMIT, "Daily limit exceeded");
        
        userDailyBridge[msg.sender] += amount;
        lastBridgeTime[msg.sender] = block.timestamp;
        
        // ✅ TRANSFER VANS ASLI
        uint256 balanceBefore = VANS_TOKEN.balanceOf(address(this));
        VANS_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = VANS_TOKEN.balanceOf(address(this));
        
        require(balanceAfter - balanceBefore == amount, "Token transfer verification failed");
        
        totalLocked += amount;
        
        bytes32 proofHash = keccak256(abi.encodePacked(
            msg.sender,
            amount,
            block.chainid,
            block.timestamp,
            userDailyBridge[msg.sender],
            "VANA_TO_ZEROG_SECURE"
        ));
        
        require(!usedProofs[proofHash], "Proof collision");
        usedProofs[proofHash] = true;
        
        emit BridgedToZeroG(msg.sender, amount, proofHash);
        return proofHash;
    }

    // ✅ BRIDGE wVANS → VANS (HANYA 0G BRIDGE)
    function bridgeFromZeroG(
        bytes32 burnProof, 
        uint256 amount, 
        address recipient,
        bytes memory signature
    ) external nonReentrant whenNotPaused {
        require(msg.sender == zeroGBridge, "Only 0G bridge");
        require(!usedProofs[burnProof], "Proof already used");
        require(amount <= totalLocked, "Insufficient liquidity");
        require(verifyVANSToken(), "Invalid VANS token");
        
        require(verifySignature(burnProof, amount, recipient, signature), "Invalid signature");
        
        usedProofs[burnProof] = true;
        totalLocked -= amount;
        
        VANS_TOKEN.safeTransfer(recipient, amount);
        emit BridgedFromZeroG(recipient, amount, burnProof);
    }

    // ✅ SIGNATURE VERIFICATION
    function verifySignature(
        bytes32 proofHash,
        uint256 amount,
        address recipient,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(
            proofHash,
            amount,
            recipient,
            block.chainid,
            "VANA_UNLOCK_SECURE"
        ));
        
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(signature);
        address recovered = ecrecover(ethSignedMessageHash, v, r, s);
        
        return recovered == zeroGBridge;
    }

    function splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "Invalid signature length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27) v += 27;
    }

    // ✅ SET ZERO G BRIDGE (ONE-TIME)
    function setZeroGBridge(address _zeroGBridge) external onlyOwner {
        require(_zeroGBridge != address(0), "Invalid bridge address");
        require(zeroGBridge == address(0), "Bridge already set");
        zeroGBridge = _zeroGBridge;
    }

    // ✅ ADMIN FUNCTIONS
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

    // ✅ EMERGENCY WITHDRAW
    function emergencyWithdrawVANS(uint256 amount) external onlyOwner {
        require(paused(), "Only when paused");
        require(amount <= VANS_TOKEN.balanceOf(address(this)), "Insufficient balance");
        VANS_TOKEN.safeTransfer(owner(), amount);
        if (amount <= totalLocked) {
            totalLocked -= amount;
        }
    }

    // ✅ VIEW FUNCTIONS
    function getBridgeInfo() external view returns (
        address vansToken,
        uint256 lockedAmount,
        uint256 bridgeFeeWei,
        bool isPaused,
        bool tokenVerified
    ) {
        return (
            address(VANS_TOKEN),
            totalLocked,
            bridgeFee,
            paused(),
            verifyVANSToken()
        );
    }

    function getVANSTokenInfo() external view returns (
        string memory name,
        string memory symbol, 
        uint256 decimals,
        uint256 totalSupply
    ) {
        return (
            VANS_TOKEN.name(),
            VANS_TOKEN.symbol(),
            VANS_TOKEN.decimals(),
            VANS_TOKEN.totalSupply()
        );
    }

    receive() external payable {}
}