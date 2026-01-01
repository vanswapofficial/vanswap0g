// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Interface ERC20
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// Interface ERC20Metadata
interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

contract STLR is IERC20, IERC20Metadata, Ownable, ReentrancyGuard {
    // Informasi dasar token
    string private constant _name = "Stellar";
    string private constant _symbol = "STLR";
    uint8 private constant _decimals = 8;
    uint256 private constant _maxSupply = 720_000 * 10**_decimals; // 720,000 STLR
    
    // State variables
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    
    // Constants untuk keamanan
    uint256 private constant MAX_UINT256 = type(uint256).max;
    
    // Events tambahan
    event TokensRecovered(address indexed token, uint256 amount);
    event NativeRecovered(uint256 amount);
    event Received(address indexed sender, uint256 amount);
    
    // Modifier untuk validasi address
    modifier validAddress(address addr) {
        require(addr != address(0), "STLR: zero address");
        require(addr != address(this), "STLR: contract address");
        _;
    }
    
    // Modifier untuk validasi amount
    modifier validAmount(uint256 amount) {
        require(amount > 0, "STLR: zero amount");
        _;
    }
    
    constructor() Ownable(msg.sender) {
        _totalSupply = _maxSupply;
        _balances[msg.sender] = _maxSupply;
        emit Transfer(address(0), msg.sender, _maxSupply);
    }
    
    // ==================== ERC20 Functions ====================
    function name() public pure override returns (string memory) {
        return _name;
    }
    
    function symbol() public pure override returns (string memory) {
        return _symbol;
    }
    
    function decimals() public pure override returns (uint8) {
        return _decimals;
    }
    
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }
    
    function maxSupply() public pure returns (uint256) {
        return _maxSupply;
    }
    
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address to, uint256 amount) 
        public 
        override 
        nonReentrant
        validAddress(to)
        validAmount(amount)
        returns (bool) 
    {
        address sender = msg.sender;
        _transfer(sender, to, amount);
        return true;
    }
    
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) 
        public 
        override 
        nonReentrant
        validAddress(spender)
        returns (bool) 
    {
        address owner = msg.sender;
        _approve(owner, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) 
        public 
        override 
        nonReentrant
        validAddress(from)
        validAddress(to)
        validAmount(amount)
        returns (bool) 
    {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }
    
    function increaseAllowance(address spender, uint256 addedValue) 
        public 
        nonReentrant
        validAddress(spender)
        returns (bool) 
    {
        address owner = msg.sender;
        _approve(owner, spender, _allowances[owner][spender] + addedValue);
        return true;
    }
    
    function decreaseAllowance(address spender, uint256 subtractedValue) 
        public 
        nonReentrant
        validAddress(spender)
        returns (bool) 
    {
        address owner = msg.sender;
        uint256 currentAllowance = _allowances[owner][spender];
        require(currentAllowance >= subtractedValue, "STLR: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }
        return true;
    }
    
    // ==================== Internal Functions ====================
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "STLR: transfer from zero address");
        require(to != address(0), "STLR: transfer to zero address");
        require(to != address(this), "STLR: transfer to contract");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "STLR: transfer amount exceeds balance");
        
        // Safe transfer dengan unchecked untuk efisiensi gas
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        
        emit Transfer(from, to, amount);
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "STLR: approve from zero address");
        require(spender != address(0), "STLR: approve to zero address");
        require(spender != address(this), "STLR: approve to contract");
        
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != MAX_UINT256) {
            require(currentAllowance >= amount, "STLR: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
    
    // ==================== Native Coin Functions ====================
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
    
    fallback() external payable {
        emit Received(msg.sender, msg.value);
    }
    
    // Fungsi untuk transfer native coin keluar (hanya owner)
    function transferNative(address payable to, uint256 amount) 
        external 
        onlyOwner 
        nonReentrant
        validAddress(to)
        validAmount(amount)
    {
        uint256 contractBalance = address(this).balance;
        require(contractBalance >= amount, "STLR: insufficient native balance");
        
        // Menggunakan call() dengan pattern CEI (Checks-Effects-Interactions)
        (bool success, ) = to.call{value: amount}("");
        require(success, "STLR: native transfer failed");
        
        emit NativeRecovered(amount);
    }
    
    // ==================== ERC20 Recovery Functions ====================
    // Fungsi untuk menyelamatkan token ERC20 yang salah dikirim ke kontrak
    function recoverERC20(address tokenAddress, uint256 amount) 
        external 
        onlyOwner 
        nonReentrant
        validAddress(tokenAddress)
        validAmount(amount)
    {
        require(tokenAddress != address(this), "STLR: cannot recover STLR token");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance >= amount, "STLR: insufficient token balance");
        
        // Transfer token dengan pattern CEI
        bool success = token.transfer(owner(), amount);
        require(success, "STLR: token transfer failed");
        
        emit TokensRecovered(tokenAddress, amount);
    }
    
    // ==================== View Functions ====================
    function getNativeBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    function getTokenBalance(address tokenAddress) external view returns (uint256) {
        require(tokenAddress != address(0), "STLR: zero address");
        IERC20 token = IERC20(tokenAddress);
        return token.balanceOf(address(this));
    }
    
    // ==================== Safety Features ====================
    // Mencegah approval ke contract ini sendiri
    function approve(address spender, uint256 amount) 
        public 
        override 
        returns (bool) 
    {
        require(spender != address(this), "STLR: cannot approve to contract itself");
        return super.approve(spender, amount);
    }
    
    // Mencegah transfer ke contract ini sendiri
    function transfer(address to, uint256 amount) 
        public 
        override 
        returns (bool) 
    {
        require(to != address(this), "STLR: cannot transfer to contract itself");
        return super.transfer(to, amount);
    }
}