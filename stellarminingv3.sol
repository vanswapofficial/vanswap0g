// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract StellarMining is ReentrancyGuard {
    IERC20 public constant STLR_TOKEN = IERC20(0xDaF91D7F48E52FB79A0413Fd44b9965110664BD0);

    address public owner;

    uint256 public constant DECIMALS = 8;
    uint256 public constant DECIMAL_FACTOR = 10**DECIMALS;

    // Mining Config
    // 0.0001 STLR per second = 10000 units (since 10^8 decimals)
    uint256 public constant BASE_RATE = 10000; 
    uint256 public constant REFERRAL_BOOST = 5000; // 50% of base
    uint256 public constant MAX_REFERRALS = 50;
    uint256 public constant MAX_SESSION = 6 hours;
    
    uint256 public minWithdraw = 100 * DECIMAL_FACTOR; 
    uint256 public constant INVITE_REWARD = 10 * DECIMAL_FACTOR; 

    // Supply & Halving
    // Reward max 230.000 STLR
    uint256 public constant MAX_MINING_SUPPLY = 230000 * DECIMAL_FACTOR;
    uint256 public totalMined;
    
    // 4 Halvings. Intervals of 46,000 STLR (230,000 / 5)
    uint256[4] public halvingThresholds;
    uint256[4] public halvingTimes; 

    bool public paused;

    uint256 public totalUsers;

    struct Miner {
        uint256 lastClaimTime;
        uint256 referralCount;
        address referrer;
        uint256 balance;
        bool hasReceivedInviteReward;
    }
    mapping(address => Miner) public miners;
    mapping(string => address) public referralCodes;
    mapping(address => string) public userToReferralCode;

    // Staking Config
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 apy;
        bool withdrawn;
    }
    mapping(address => Stake[]) public userStakes;
    mapping(uint256 => uint256) public durationToApy;

    uint256 public minStake = 10 * DECIMAL_FACTOR;
    uint256 public maxStake = 1000 * DECIMAL_FACTOR;
    
    // Tracking for safety/separation
    uint256 public totalStaked; 

    event Mined(address indexed user, uint256 amount);
    event WithdrawnMining(address indexed user, uint256 amount, uint256 fee);
    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ApyUpdated(uint256 duration, uint256 newApy);
    event ReferrerSet(address indexed user, address indexed referrer, uint256 bonusAmount);
    event Registered(address indexed user, string code);
    event HalvingTriggered(uint256 level, uint256 timestamp);
    event Paused(bool isPaused);

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Contracts not allowed");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Airdrop is paused");
        _;
    }

    constructor() {
        owner = msg.sender;
        require(address(STLR_TOKEN) != address(0), "Token address is zero");

        durationToApy[1] = 85;
        durationToApy[3] = 150;
        durationToApy[6] = 250;
        durationToApy[12] = 600;

        // Initialize thresholds (46k, 92k, 138k, 184k)
        halvingThresholds[0] = 46000 * DECIMAL_FACTOR;
        halvingThresholds[1] = 92000 * DECIMAL_FACTOR;
        halvingThresholds[2] = 138000 * DECIMAL_FACTOR;
        halvingThresholds[3] = 184000 * DECIMAL_FACTOR;
    }

    receive() external payable {
        // Accept native coins
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }
    
    function setMinWithdraw(uint256 _min) external onlyOwner {
        minWithdraw = _min;
    }

    function withdrawNative() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No native coin");
        (bool success, ) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }

    function setReferrer(string memory code) external onlyEOA nonReentrant whenNotPaused {
        address ref = referralCodes[code];
        require(ref != address(0) && ref != msg.sender, "Invalid referrer");
        require(miners[msg.sender].referrer == address(0), "Already has referrer");

        miners[msg.sender].referrer = ref;

        // Boost referrer
        if (miners[ref].referralCount < MAX_REFERRALS) {
            miners[ref].referralCount++;
        }

        if (!miners[msg.sender].hasReceivedInviteReward) {
            miners[msg.sender].hasReceivedInviteReward = true;
            miners[msg.sender].balance += INVITE_REWARD;
            // Invite reward is a one-time bonus, we don't count it towards mining supply limit logic here
            // to keep it simple, or we can add it. Since it's 'bonus', let's treat it separate from 'mining' rate.
            
            emit ReferrerSet(msg.sender, ref, INVITE_REWARD);
        }
    }

    function autoRegister() external onlyEOA nonReentrant whenNotPaused {
        require(bytes(userToReferralCode[msg.sender]).length == 0, "Already registered");

        totalUsers++;

        string memory suffix = _toString(totalUsers);
        string memory code;
        if (totalUsers < 10) {
            code = string(abi.encodePacked("STLR0", suffix));
        } else {
            code = string(abi.encodePacked("STLR", suffix));
        }

        referralCodes[code] = msg.sender;
        userToReferralCode[msg.sender] = code;

        emit Registered(msg.sender, code);
    }

    function claimMiningRewards() external onlyEOA nonReentrant whenNotPaused {
        Miner storage m = miners[msg.sender];
        uint256 currentTime = block.timestamp;

        if (m.lastClaimTime == 0) {
            m.lastClaimTime = currentTime;
            return;
        }
        
        if (totalMined >= MAX_MINING_SUPPLY) {
            m.lastClaimTime = currentTime;
            return; // Mining finished
        }

        uint256 timeElapsed = currentTime - m.lastClaimTime;
        require(timeElapsed >= MAX_SESSION, "Mining in progress"); 

        uint256 reward = _calculateReward(m.lastClaimTime, currentTime, m.referralCount);

        if (totalMined + reward > MAX_MINING_SUPPLY) {
            reward = MAX_MINING_SUPPLY - totalMined;
        }

        if (reward > 0) {
            m.balance += reward;
            totalMined += reward;
            emit Mined(msg.sender, reward);
        }
        
        m.lastClaimTime = currentTime;
        
        _checkHalving();
    }
    
    function _calculateReward(uint256 startTime, uint256 endTime, uint256 referrals) internal view returns (uint256) {
        uint256 totalReward = 0;
        uint256 t = startTime;
        uint256 miningEnd = startTime + MAX_SESSION;
        if (miningEnd > endTime) miningEnd = endTime; 
        
        // Calculate reward by integrating rate over time, accounting for halving events
        while (t < miningEnd) {
            uint256 currentRate = _getRateAtTime(t, referrals);
            uint256 nextEvent = miningEnd;
            
            // Find the nearest future halving time
            for (uint i = 0; i < 4; i++) {
                if (halvingTimes[i] != 0 && halvingTimes[i] > t && halvingTimes[i] < nextEvent) {
                    nextEvent = halvingTimes[i];
                }
            }
            
            uint256 dur = nextEvent - t;
            totalReward += dur * currentRate;
            t = nextEvent;
        }
        
        return totalReward;
    }
    
    function _getRateAtTime(uint256 t, uint256 referrals) internal view returns (uint256) {
        uint256 stage = 0;
        for (uint i = 0; i < 4; i++) {
            if (halvingTimes[i] != 0 && t >= halvingTimes[i]) {
                stage++;
            }
        }
        
        // Halve rate and boost for each stage
        uint256 rate = BASE_RATE >> stage; 
        uint256 boost = REFERRAL_BOOST >> stage;
        
        return rate + (referrals * boost);
    }
    
    function _checkHalving() internal {
        for (uint i = 0; i < 4; i++) {
            if (halvingTimes[i] == 0 && totalMined >= halvingThresholds[i]) {
                halvingTimes[i] = block.timestamp;
                emit HalvingTriggered(i + 1, block.timestamp);
            }
        }
    }

    function withdrawMining(uint256 amount) external payable onlyEOA nonReentrant whenNotPaused {
        Miner storage m = miners[msg.sender];
        require(m.balance >= amount, "Insufficient balance");
        require(amount >= minWithdraw, "Below min withdraw");
        require(STLR_TOKEN.balanceOf(address(this)) >= amount, "Contract empty");
        
        // 1. Check user wallet balance (Native Coin)
        require(address(msg.sender).balance >= 5 ether, "Must hold 5 BERA");
        
        // 2. Check and take fee
        // Fee: 0.1 BERA per 100 STLR (100 * 10^8 units)
        // fee = amount * 0.1 / 100 (adjusted for decimals)
        // amount is in 10^8. 0.1 ether is 10^17 wei.
        // fee = (amount * 1e17) / (100 * 10^8)
        uint256 fee = (amount * 1e17) / (100 * DECIMAL_FACTOR);
        require(msg.value >= fee, "Insufficient fee");
        
        m.balance -= amount;
        
        require(STLR_TOKEN.transfer(msg.sender, amount), "Transfer failed");
        
        if (fee > 0) {
            (bool success, ) = owner.call{value: fee}("");
            require(success, "Fee transfer failed");
        }
        
        // Refund excess fee if any? (Usually not needed if exact, but good practice if user sends too much)
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }

        emit WithdrawnMining(msg.sender, amount, fee);
    }

    function getPendingReward(address user) external view returns (uint256) {
        Miner memory m = miners[user];
        if (m.lastClaimTime == 0) return 0;

        uint256 currentTime = block.timestamp;
        
        uint256 end = currentTime;
        if (end > m.lastClaimTime + MAX_SESSION) {
            end = m.lastClaimTime + MAX_SESSION;
        }
        
        if (end <= m.lastClaimTime) return 0;
        
        return _calculateReward(m.lastClaimTime, end, m.referralCount);
    }

    function getMiningBalance(address user) external view returns (uint256) {
        return miners[user].balance;
    }

    // Staking functions
    function stake(uint256 amount, uint256 durationMonths) external onlyEOA nonReentrant {
        require(amount >= minStake && amount <= maxStake, "Invalid amount");
        uint256 apy = durationToApy[durationMonths];
        require(apy > 0, "Invalid duration");

        uint256 durationSec = durationMonths * 30 days;

        require(STLR_TOKEN.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        userStakes[msg.sender].push(Stake({
            amount: amount,
            startTime: block.timestamp,
            duration: durationSec,
            apy: apy,
            withdrawn: false
        }));
        
        totalStaked += amount;

        emit Staked(msg.sender, amount, durationSec);
    }

    function withdrawStake(uint256 index) external onlyEOA nonReentrant {
        require(index < userStakes[msg.sender].length, "Invalid index");
        Stake storage s = userStakes[msg.sender][index];
        require(!s.withdrawn, "Already withdrawn");
        require(block.timestamp >= s.startTime + s.duration, "Locked");

        s.withdrawn = true;

        uint256 reward = (s.amount * s.apy * s.duration) / (100 * 365 days);
        uint256 total = s.amount + reward;

        require(STLR_TOKEN.balanceOf(address(this)) >= total, "Contract empty");
        require(STLR_TOKEN.transfer(msg.sender, total), "Transfer failed");
        
        totalStaked -= s.amount;

        emit Unstaked(msg.sender, s.amount, reward);
    }

    // Utility functions
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function getUserStakes(address user) external view returns (Stake[] memory) {
        return userStakes[user];
    }

    function getMinerInfo(address user) external view returns (
        uint256 lastClaimTime,
        uint256 referralCount,
        address referrer,
        uint256 balance,
        bool hasReceivedInviteReward,
        string memory referralCode
    ) {
        Miner memory m = miners[user];
        return (
            m.lastClaimTime,
            m.referralCount,
            m.referrer,
            m.balance,
            m.hasReceivedInviteReward,
            userToReferralCode[user]
        );
    }

    function getContractTokenBalance() external view returns (uint256) {
        return STLR_TOKEN.balanceOf(address(this));
    }

    function getTokenAddress() external pure returns (address) {
        return address(STLR_TOKEN);
    }

    function getTokenDecimals() external pure returns (uint256) {
        return DECIMALS;
    }
}
