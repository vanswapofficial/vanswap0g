// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract EVOLUT {
    // === TOKEN INFO ===
    string public constant name = "EVOLUT";
    string public constant symbol = "EVO";
    uint8 public constant decimals = 18;
    uint256 public constant MAX_SUPPLY = 100_000 * 10**18; // 100.000 max
    
    // === STATE VARIABLES ===
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    
    uint256 private _totalSupply; // Track current supply (circulating)
    
    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address spender, uint256 value);
    event Mint(address indexed to, uint256 amount);
    event NativeReceived(address indexed from, uint256 value);
    event NativeSent(address indexed to, uint256 value);
    
    // Owner
    address public owner;
    bool public mintingEnabled = true;
    
    // === REENTRANCY GUARD ===
    bool private _reentrancyLock;
    
    modifier nonReentrant() {
        require(!_reentrancyLock, "EVO: REENTRANCY_DETECTED");
        _reentrancyLock = true;
        _;
        _reentrancyLock = false;
    }
    
    // === CONSTRUCTOR ===
    constructor() {
        owner = msg.sender;
        // Mint initial 500 token ke deployer (circulating supply)
        _mint(msg.sender, 500 * 10**18);
    }
    
    // === MODIFIERS ===
    modifier onlyOwner() {
        require(msg.sender == owner, "EVO: NOT_OWNER");
        _;
    }
    
    // === ERC20 STANDARD ===
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }
    
    function approve(address spender, uint256 value) public returns (bool) {
        address owner_ = msg.sender;
        _allowances[owner_][spender] = value;
        emit Approval(owner_, spender, value);
        return true;
    }
    
    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }
    
    // === MINT FUNCTION ===
    function mint(address to, uint256 amount) public onlyOwner {
        require(mintingEnabled, "EVO: MINTING_DISABLED");
        require(to != address(0), "EVO: MINT_TO_ZERO");
        require(amount > 0, "EVO: MINT_AMOUNT_ZERO");
        require(_totalSupply + amount <= MAX_SUPPLY, "EVO: EXCEEDS_MAX_SUPPLY");
        
        _mint(to, amount);
        emit Mint(to, amount);
    }
    
    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    // === BURN FUNCTION ===
    function burn(uint256 amount) public {
        require(amount > 0, "EVO: BURN_ZERO");
        require(_balances[msg.sender] >= amount, "EVO: INSUFFICIENT_BURN");
        
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
    
    // === NATIVE TOKEN SUPPORT ===
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }
    
    fallback() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }
    
    function sendNative(address payable to, uint256 amount) public onlyOwner nonReentrant {
        require(address(this).balance >= amount, "EVO: INSUFFICIENT_NATIVE");
        (bool success, ) = to.call{value: amount}("");
        require(success, "EVO: NATIVE_TRANSFER_FAILED");
        emit NativeSent(to, amount);
    }
    
    function nativeBalance() public view returns (uint256) {
        return address(this).balance;
    }
    
    // === ERC20 TOKEN SUPPORT ===
    function transferERC20(address tokenAddress, address to, uint256 amount) public onlyOwner nonReentrant {
        IERC20 token = IERC20(tokenAddress);
        bool success = token.transfer(to, amount);
        require(success, "EVO: ERC20_TRANSFER_FAILED");
    }
    
    function transferAllERC20(address tokenAddress, address to) public onlyOwner nonReentrant {
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "EVO: NO_ERC20_BALANCE");
        bool success = token.transfer(to, balance);
        require(success, "EVO: ERC20_TRANSFER_FAILED");
    }
    
    // === INTERNAL FUNCTIONS ===
    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0), "EVO: FROM_ZERO_ADDRESS");
        require(to != address(0), "EVO: TO_ZERO_ADDRESS");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= value, "EVO: INSUFFICIENT_BALANCE");
        
        unchecked {
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        
        emit Transfer(from, to, value);
    }
    
    function _spendAllowance(address owner_, address spender, uint256 value) internal {
        uint256 currentAllowance = allowance(owner_, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= value, "EVO: INSUFFICIENT_ALLOWANCE");
            unchecked {
                _approve(owner_, spender, currentAllowance - value);
            }
        }
    }
    
    function _approve(address owner_, address spender, uint256 value) internal {
        require(owner_ != address(0), "EVO: APPROVE_FROM_ZERO");
        require(spender != address(0), "EVO: APPROVE_TO_ZERO");
        
        _allowances[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }
    
    // === OWNER FUNCTIONS ===
    function disableMinting() public onlyOwner {
        mintingEnabled = false;
    }
    
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "EVO: NEW_OWNER_ZERO");
        owner = newOwner;
    }
    
    function renounceOwnership() public onlyOwner {
        owner = address(0);
        mintingEnabled = false; // Auto-disable minting
    }
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}