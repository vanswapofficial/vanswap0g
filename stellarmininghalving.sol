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

contract StellarMiningWithHalving is ReentrancyGuard {
    IERC20 public constant STLR_TOKEN = IERC20(0xDaF91D7F48E52FB79A0413Fd44b9965110664BD0);

    address public owner;

    uint256 public constant DECIMALS = 8;
    uint256 public constant DECIMAL_FACTOR = 10**DECIMALS;

    // Mining Config dengan HALVING
    uint256 public constant INITIAL_BASE_RATE = 100000; // 0.001 STLR per second (8 decimals) - AWAL TINGGI
    uint256 public constant REFERRAL_BOOST = 50000; // 0.0005 STLR per second
    uint256 public constant MAX_REFERRALS = 50;
    uint256 public constant MAX_SESSION = 6 hours;
    uint256 public constant MIN_WITHDRAW = 100 * DECIMAL_FACTOR; // 100 STLR
    uint256 public constant INVITE_REWARD = 10 * DECIMAL_FACTOR; // 10 STLR bonus

    // HALVING CONFIG
    uint256 public constant MAX_TOTAL_SUPPLY = 144000 * DECIMAL_FACTOR; // 144,000 STLR
    uint256 public constant HALVING_PERIOD = 180 days; // 6 bulan
    uint256 public constant TOTAL_HALVINGS = 4; // Total 4x halving (2 tahun)
    uint256 public constant INITIAL_HALVING_SUPPLY = 72000 * DECIMAL_FACTOR; // 72,000 untuk periode pertama
    
    uint256 public totalUsers;
    uint256 public totalMined; // Total yang sudah ditambang
    uint256 public currentHalving = 0; // Periode halving saat ini (0-4)
    uint256 public halvingStartTime; // Waktu mulai halving pertama
    uint256 public currentBaseRate = INITIAL_BASE_RATE; // Rate saat ini

    struct Miner {
        uint256 lastClaimTime;
        uint256 referralCount;
        address referrer;
        uint256 miningBalance;
        bool hasReceivedInviteReward;
        uint256 totalMined; // Total yang sudah ditambang oleh user ini
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
    
    // VARIABEL TERPISAH untuk melacak saldo
    uint256 public totalStaked;
    uint256 public totalMiningRewards;

    event Mined(address indexed user, uint256 amount);
    event WithdrawnMining(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ApyUpdated(uint256 duration, uint256 newApy);
    event ReferrerSet(address indexed user, address indexed referrer, uint256 bonusAmount);
    event Registered(address indexed user, string code);
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    event HalvingTriggered(uint256 newBaseRate, uint256 halvingNumber, uint256 remainingSupply);
    event MiningRateAdjusted(uint256 newBaseRate);

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Contracts not allowed");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        require(address(STLR_TOKEN) != address(0), "Token address is zero");
        
        // Set waktu mulai halving
        halvingStartTime = block.timestamp;
        
        durationToApy[1] = 85;
        durationToApy[3] = 150;
        durationToApy[6] = 250;
        durationToApy[12] = 600;
    }

    // FUNGSI HALVING
    function checkAndApplyHalving() internal returns (bool halvingApplied) {
        uint256 timeSinceStart = block.timestamp - halvingStartTime;
        uint256 expectedHalving = timeSinceStart / HALVING_PERIOD;
        
        if (expectedHalving > TOTAL_HALVINGS) {
            expectedHalving = TOTAL_HALVINGS;
        }
        
        // Jika ada halving baru
        if (expectedHalving > currentHalving) {
            uint256 oldHalving = currentHalving;
            currentHalving = expectedHalving;
            
            // Hitung supply yang tersisa untuk periode ini
            uint256 remainingSupply = getRemainingSupply();
            
            // Hitung base rate baru berdasarkan halving
            // Periode 0: 100% (INITIAL_BASE_RATE)
            // Periode 1: 50%
            // Periode 2: 25%
            // Periode 3: 12.5%
            // Periode 4: 6.25%
            
            currentBaseRate = INITIAL_BASE_RATE;
            for (uint256 i = 0; i < currentHalving; i++) {
                currentBaseRate = currentBaseRate / 2;
            }
            
            // Minimal rate 1% dari initial
            if (currentBaseRate < INITIAL_BASE_RATE / 100) {
                currentBaseRate = INITIAL_BASE_RATE / 100;
            }
            
            emit HalvingTriggered(currentBaseRate, currentHalving, remainingSupply);
            return true;
        }
        return false;
    }

    function getHalvingInfo() public view returns (
        uint256 currentHalvingPeriod,
        uint256 nextHalvingTime,
        uint256 currentRate,
        uint256 remainingSupply,
        uint256 minedPercentage,
        uint256 daysUntilNextHalving
    ) {
        uint256 timeSinceStart = block.timestamp - halvingStartTime;
        uint256 expectedHalving = timeSinceStart / HALVING_PERIOD;
        
        if (expectedHalving > TOTAL_HALVINGS) {
            expectedHalving = TOTAL_HALVINGS;
        }
        
        uint256 nextHalvingTimestamp = halvingStartTime + ((expectedHalving + 1) * HALVING_PERIOD);
        
        // Hitung rate saat ini
        uint256 tempRate = INITIAL_BASE_RATE;
        for (uint256 i = 0; i < expectedHalving; i++) {
            tempRate = tempRate / 2;
        }
        if (tempRate < INITIAL_BASE_RATE / 100) {
            tempRate = INITIAL_BASE_RATE / 100;
        }
        
        uint256 remaining = getRemainingSupply();
        uint256 minedPercent = (totalMined * 10000) / MAX_TOTAL_SUPPLY; // Basis points
        
        uint256 daysToNext = 0;
        if (expectedHalving < TOTAL_HALVINGS) {
            daysToNext = (nextHalvingTimestamp - block.timestamp) / 1 days;
        }
        
        return (
            expectedHalving,
            nextHalvingTimestamp,
            tempRate,
            remaining,
            minedPercent,
            daysToNext
        );
    }

    function getRemainingSupply() public view returns (uint256) {
        if (totalMined >= MAX_TOTAL_SUPPLY) {
            return 0;
        }
        return MAX_TOTAL_SUPPLY - totalMined;
    }

    function getCurrentBaseRate() public view returns (uint256) {
        uint256 timeSinceStart = block.timestamp - halvingStartTime;
        uint256 expectedHalving = timeSinceStart / HALVING_PERIOD;
        
        if (expectedHalving > TOTAL_HALVINGS) {
            expectedHalving = TOTAL_HALVINGS;
        }
        
        uint256 rate = INITIAL_BASE_RATE;
        for (uint256 i = 0; i < expectedHalving; i++) {
            rate = rate / 2;
        }
        
        if (rate < INITIAL_BASE_RATE / 100) {
            rate = INITIAL_BASE_RATE / 100;
        }
        
        return rate;
    }

    receive() external payable {
        // Accept native coins
    }

    function withdrawNative() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No native coin");
        (bool success, ) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }

    function setReferrer(string memory code) external onlyEOA nonReentrant {
        address ref = referralCodes[code];
        require(ref != address(0) && ref != msg.sender, "Invalid referrer");
        require(miners[msg.sender].referrer == address(0), "Already has referrer");

        miners[msg.sender].referrer = ref;

        // Boost referrer
        if (miners[ref].referralCount < MAX_REFERRALS) {
            miners[ref].referralCount++;
        }

        // Tambah bonus ke mining balance (TERPISAH dari staking)
        if (!miners[msg.sender].hasReceivedInviteReward) {
            miners[msg.sender].hasReceivedInviteReward = true;
            
            // PERIKSA SUPPLY SEBELUM TAMBAH BONUS
            uint256 remaining = getRemainingSupply();
            require(remaining >= INVITE_REWARD, "Mining supply exhausted");
            
            miners[msg.sender].miningBalance += INVITE_REWARD;
            totalMiningRewards += INVITE_REWARD;
            totalMined += INVITE_REWARD;
            
            emit ReferrerSet(msg.sender, ref, INVITE_REWARD);
        }
    }

    function autoRegister() external onlyEOA nonReentrant {
        require(bytes(userToReferralCode[msg.sender]).length == 0, "Already registered");

        totalUsers++;

        // Generate referral code: STLR + number
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

    function claimMiningRewards() external onlyEOA nonReentrant {
        Miner storage m = miners[msg.sender];
        uint256 currentTime = block.timestamp;

        // Update halving jika perlu
        checkAndApplyHalving();

        if (m.lastClaimTime == 0) {
            m.lastClaimTime = currentTime;
            return;
        }

        uint256 timeElapsed = currentTime - m.lastClaimTime;
        require(timeElapsed >= MAX_SESSION, "Mining in progress");

        uint256 effectiveTime = MAX_SESSION;
        
        // Gunakan currentBaseRate yang sudah di-update
        uint256 rate = currentBaseRate + (m.referralCount * REFERRAL_BOOST);
        uint256 reward = effectiveTime * rate;
        
        // CEK SUPPLY TERSEDIA
        uint256 remainingSupply = getRemainingSupply();
        if (reward > remainingSupply) {
            reward = remainingSupply; // Max sampai supply habis
        }
        
        require(reward > 0, "No mining reward available");
        
        // Update totals
        m.miningBalance += reward;
        m.totalMined += reward;
        m.lastClaimTime = currentTime;
        
        totalMiningRewards += reward;
        totalMined += reward;

        emit Mined(msg.sender, reward);
        
        // Jika supply hampir habis, adjust rate
        if (remainingSupply <= MAX_TOTAL_SUPPLY / 100) { // Kurang dari 1% supply
            uint256 newRate = currentBaseRate / 2;
            if (newRate > 0) {
                currentBaseRate = newRate;
                emit MiningRateAdjusted(newRate);
            }
        }
    }

    function withdrawMining(uint256 amount) external onlyEOA nonReentrant {
        Miner storage m = miners[msg.sender];
        require(m.miningBalance >= amount, "Insufficient mining balance");
        require(amount >= MIN_WITHDRAW, "Below min withdraw");
        
        uint256 availableForMining = STLR_TOKEN.balanceOf(address(this)) - totalStaked;
        require(availableForMining >= amount, "Insufficient mining funds in contract");

        m.miningBalance -= amount;
        totalMiningRewards -= amount;
        
        require(STLR_TOKEN.transfer(msg.sender, amount), "Transfer failed");

        emit WithdrawnMining(msg.sender, amount);
    }

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
        
        totalStaked -= s.amount;
        
        require(STLR_TOKEN.transfer(msg.sender, total), "Transfer failed");

        emit Unstaked(msg.sender, s.amount, reward);
    }

    function depositMiningRewards(uint256 amount) external onlyOwner nonReentrant {
        require(STLR_TOKEN.transferFrom(msg.sender, address(this), amount), "Transfer failed");
    }

    function getContractFundsStatus() external view returns (
        uint256 contractBalance,
        uint256 totalStakedFunds,
        uint256 totalMiningFunds,
        uint256 availableForMining,
        uint256 availableForStaking,
        uint256 maxTotalSupply,
        uint256 minedSoFar,
        uint256 remainingMiningSupply
    ) {
        contractBalance = STLR_TOKEN.balanceOf(address(this));
        uint256 miningReserve = totalMiningRewards;
        uint256 stakingReserve = totalStaked;
        
        availableForMining = contractBalance > stakingReserve ? contractBalance - stakingReserve : 0;
        availableForStaking = contractBalance > miningReserve ? contractBalance - miningReserve : 0;
        
        return (
            contractBalance,
            stakingReserve,
            miningReserve,
            availableForMining,
            availableForStaking,
            MAX_TOTAL_SUPPLY,
            totalMined,
            getRemainingSupply()
        );
    }

    function getPendingReward(address user) external view returns (uint256) {
        Miner memory m = miners[user];
        if (m.lastClaimTime == 0) return 0;

        uint256 timeElapsed = block.timestamp - m.lastClaimTime;
        if (timeElapsed > MAX_SESSION) {
            timeElapsed = MAX_SESSION;
        }

        uint256 currentRate = getCurrentBaseRate();
        uint256 rate = currentRate + (m.referralCount * REFERRAL_BOOST);
        uint256 reward = timeElapsed * rate;
        
        // Batasi dengan supply yang tersisa
        uint256 remaining = getRemainingSupply();
        return reward > remaining ? remaining : reward;
    }

    function getMiningBalance(address user) external view returns (uint256) {
        return miners[user].miningBalance;
    }

    // Utility functions...
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
        uint256 miningBalance,
        uint256 totalMinedByUser,
        bool hasReceivedInviteReward,
        string memory referralCode
    ) {
        Miner memory m = miners[user];
        return (
            m.lastClaimTime,
            m.referralCount,
            m.referrer,
            m.miningBalance,
            m.totalMined,
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
    
    function emergencyWithdrawExcess(uint256 amount) external onlyOwner nonReentrant {
        uint256 contractBalance = STLR_TOKEN.balanceOf(address(this));
        uint256 requiredReserve = totalStaked + totalMiningRewards;
        
        require(contractBalance > requiredReserve, "No excess funds");
        
        uint256 excess = contractBalance - requiredReserve;
        require(amount <= excess, "Amount exceeds excess funds");
        
        require(STLR_TOKEN.transfer(owner, amount), "Transfer failed");
        emit EmergencyWithdraw(owner, amount);
    }
    
    // FUNGSI UNTUK MANUAL TRIGGER HALVING (testing purposes)
    function forceHalving() external onlyOwner {
        if (currentHalving < TOTAL_HALVINGS) {
            currentHalving++;
            
            // Apply halving
            currentBaseRate = currentBaseRate / 2;
            if (currentBaseRate < INITIAL_BASE_RATE / 100) {
                currentBaseRate = INITIAL_BASE_RATE / 100;
            }
            
            emit HalvingTriggered(currentBaseRate, currentHalving, getRemainingSupply());
        }
    }
    
    // FUNGSI UNTUK SET WAKTU HALVING (emergency/launch adjustment)
    function setHalvingStartTime(uint256 newStartTime) external onlyOwner {
        require(newStartTime <= block.timestamp, "Cannot set future time");
        halvingStartTime = newStartTime;
    }
}