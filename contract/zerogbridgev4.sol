// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ZeroGBridge is ERC20, ReentrancyGuard, Ownable, Pausable {
    uint256 public constant MAX_SUPPLY = 48_000_000 * 10**18;
    
    mapping(bytes32 => bool) public usedProofs;
    uint256 public totalBridged;

    event BridgedToVana(address indexed user, uint256 amount, bytes32 proofHash);
    event BridgedFromVana(address indexed user, uint256 amount, bytes32 proofHash);

    constructor() ERC20("Wrapped VANS", "wVANS") Ownable(msg.sender) {
        // Pre-mint ke kontrak sendiri
        _mint(address(this), MAX_SUPPLY);
    }

    // ✅ TRANSFER 1:1 - tidak ada potongan
    function completeBridgeFromVana(
        bytes32 vanaProof,
        uint256 amount, 
        address recipient
    ) external nonReentrant whenNotPaused {
        require(!usedProofs[vanaProof], "Proof already used");
        require(amount > 0, "Invalid amount");
        require(balanceOf(address(this)) >= amount, "Insufficient bridge liquidity");
        
        usedProofs[vanaProof] = true;
        totalBridged += amount;
        
        // ✅ TRANSFER 1:1 - amount sama persis
        _transfer(address(this), recipient, amount);

        emit BridgedFromVana(recipient, amount, vanaProof);
    }

    // ✅ BURN 1:1 - amount sama persis
    function burnToVana(uint256 amount) external nonReentrant whenNotPaused returns (bytes32) {
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Transfer wVANS ke kontrak (1:1)
        _transfer(msg.sender, address(this), amount);

        bytes32 proofHash = keccak256(abi.encodePacked(
            msg.sender, 
            amount, 
            block.chainid, 
            block.timestamp,
            "0G_TO_VANA"
        ));

        require(!usedProofs[proofHash], "Proof collision");
        usedProofs[proofHash] = true;

        emit BridgedToVana(msg.sender, amount, proofHash);
        return proofHash;
    }

    function bridgeLiquidity() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}