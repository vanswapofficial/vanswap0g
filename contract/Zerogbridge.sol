// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ZeroGBridge is ERC20, ReentrancyGuard, Ownable, Pausable {
    uint256 public constant MAX_SUPPLY = 48_000_000 * 10**18;
    
    address public vanaBridge;
    mapping(bytes32 => bool) public usedProofs;
    uint256 public totalMinted;
    
    event BridgedToVana(address indexed user, uint256 amount, bytes32 proofHash);
    event BridgedFromVana(address indexed user, uint256 amount, bytes32 proofHash);

    // ✅ TAMBAHKAN PARAMETER UNTUK Ownable
    constructor() ERC20("Wrapped VANS", "wVANS") Ownable(msg.sender) {
        // ✅ msg.sender (deployer) jadi owner
    }

    function bridgeToVana(uint256 amount) external nonReentrant whenNotPaused returns (bytes32) {
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        _burn(msg.sender, amount);
        
        bytes32 proofHash = keccak256(abi.encodePacked(
            msg.sender, amount, block.chainid, block.timestamp, "ZEROG_TO_VANA"
        ));
        
        require(!usedProofs[proofHash], "Proof collision");
        usedProofs[proofHash] = true;
        
        emit BridgedToVana(msg.sender, amount, proofHash);
        return proofHash;
    }

    function bridgeFromVana(bytes32 lockProof, uint256 amount, address recipient) external nonReentrant whenNotPaused {
        require(msg.sender == vanaBridge, "Only Vana bridge");
        require(!usedProofs[lockProof], "Proof already used");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds supply");
        
        usedProofs[lockProof] = true;
        totalMinted += amount;
        _mint(recipient, amount);
        
        emit BridgedFromVana(recipient, amount, lockProof);
    }

    // ✅ ADMIN FUNCTIONS - HANYA OWNER (DEPLOYER)
    function setVanaBridge(address _vanaBridge) external onlyOwner {
        vanaBridge = _vanaBridge;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyBurn(address account, uint256 amount) external onlyOwner {
        require(paused(), "Only when paused");
        _burn(account, amount);
    }
}