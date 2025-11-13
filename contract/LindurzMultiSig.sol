// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title LindurzMultiSigWallet
 */
contract LindurzMultiSigWallet is ReentrancyGuard {
    // Events
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequirementChanged(uint256 required);
    event TransactionSubmitted(uint256 indexed transactionId);
    event TransactionConfirmed(address indexed owner, uint256 indexed transactionId);
    event TransactionExecuted(uint256 indexed transactionId);
    event DepositReceived(address indexed sender, uint256 amount);

    // Struct
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    // State variables
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public required;
    bool public initialized;
    
    Transaction[] public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmations;

    // Modifiers
    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier notInitialized() {
        require(!initialized, "Already initialized");
        _;
    }

    modifier validRequirement(uint256 _required) {
        require(_required > 0 && _required <= owners.length, "Invalid requirement");
        _;
    }

    /**
     * @dev Constructor - hanya deploy, setup dilakukan setelahnya
     */
    constructor() {
        // Kosong - setup dilakukan melalui initialize
    }

    /**
     * @dev Initialize wallet dengan owners dan required
     * @param _owners Array of owner addresses
     * @param _required Required confirmations
     */
    function initialize(address[] memory _owners, uint256 _required) 
        external 
        notInitialized 
        validRequirement(_required) 
    {
        require(_owners.length > 0, "At least one owner required");
        
        for (uint256 i = 0; i < _owners.length; i++) {
            require(_owners[i] != address(0), "Invalid owner address");
            require(!isOwner[_owners[i]], "Duplicate owner");
            
            isOwner[_owners[i]] = true;
            owners.push(_owners[i]);
        }
        
        required = _required;
        initialized = true;
    }

    /**
     * @dev Add new owner (butuh konfirmasi dari owners existing)
     */
    function addOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        require(!isOwner[newOwner], "Already an owner");
        
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);
    }

    /**
     * @dev Set required confirmations
     */
    function setRequired(uint256 _required) external onlyOwner validRequirement(_required) {
        required = _required;
        emit RequirementChanged(_required);
    }

    /**
     * @dev Submit new transaction
     */
    function submitTransaction(address to, uint256 value, bytes memory data) 
        external 
        onlyOwner 
        returns (uint256) 
    {
        uint256 transactionId = transactions.length;
        transactions.push(Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            confirmations: 0
        }));
        
        emit TransactionSubmitted(transactionId);
        confirmTransaction(transactionId); // Auto-confirm by submitter
        
        return transactionId;
    }

    /**
     * @dev Confirm transaction
     */
    function confirmTransaction(uint256 transactionId) public onlyOwner {
        require(transactionId < transactions.length, "Invalid transaction ID");
        require(!confirmations[transactionId][msg.sender], "Already confirmed");
        
        Transaction storage txn = transactions[transactionId];
        require(!txn.executed, "Transaction already executed");
        
        confirmations[transactionId][msg.sender] = true;
        txn.confirmations++;
        
        emit TransactionConfirmed(msg.sender, transactionId);
        
        // Auto-execute if enough confirmations
        if (txn.confirmations >= required) {
            executeTransaction(transactionId);
        }
    }

    /**
     * @dev Execute transaction
     */
    function executeTransaction(uint256 transactionId) public nonReentrant {
        require(transactionId < transactions.length, "Invalid transaction ID");
        
        Transaction storage txn = transactions[transactionId];
        require(!txn.executed, "Already executed");
        require(txn.confirmations >= required, "Not enough confirmations");
        
        txn.executed = true;
        
        (bool success, ) = txn.to.call{value: txn.value}(txn.data);
        require(success, "Transaction failed");
        
        emit TransactionExecuted(transactionId);
    }

    /**
     * @dev Receive ETH
     */
    receive() external payable {
        if (msg.value > 0) {
            emit DepositReceived(msg.sender, msg.value);
        }
    }

    // View functions
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function isConfirmed(uint256 transactionId) external view returns (bool) {
        require(transactionId < transactions.length, "Invalid transaction ID");
        return transactions[transactionId].confirmations >= required;
    }
}