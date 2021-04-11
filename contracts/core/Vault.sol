// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "../oracle/interfaces/IPriceFeed.sol";

import "../tokens/interfaces/IUSDG.sol";
import "./interfaces/IVault.sol";

contract Vault is ReentrancyGuard, IVault {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
    }

    uint256 constant BASIS_POINTS_DIVISOR = 10000;
    uint256 constant FUNDING_RATE_PRECISION = 1000000;
    uint256 constant PRICE_PRECISION = 10 ** 30;
    uint256 constant MIN_LEVERAGE = 10000; // 1x
    uint256 constant USDG_DECIMALS = 18;
    uint256 constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public isInitialized;

    address public router;

    address public usdg;
    address public gov;

    uint256 public maxUsdg;
    uint256 public maxLeverage = 50 * 10000; // 50x
    uint256 public priceSampleSpace = 3;

    uint256 public liquidationFeeUsd;
    uint256 public swapFeeBasisPoints = 30; // 0.3%
    uint256 public stableSwapFeeBasisPoints = 4; // 0.04%
    uint256 public marginFeeBasisPoints = 10; // 0.1%

    uint256 public fundingInterval = 8 hours;
    uint256 public override fundingRateFactor;

    mapping (address => mapping (address => bool)) public approvedRouters;

    mapping (address => bool) public whitelistedTokens;
    mapping (address => address) public priceFeeds;
    mapping (address => uint256) public priceDecimals;
    mapping (address => uint256) public tokenDecimals;
    mapping (address => uint256) public redemptionBasisPoints;
    mapping (address => uint256) public minProfitBasisPoints;
    mapping (address => bool) public stableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping (address => uint256) public tokenBalances;

    // usdgAmounts tracks the amount of USDG debt for each whitelisted token
    mapping (address => uint256) public override usdgAmounts;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    mapping (address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping (address => uint256) public override reservedAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    // this value is used to calculate the redemption values for selling of USDG
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    mapping (address => uint256) public guaranteedUsd;

    mapping (address => uint256) public override cumulativeFundingRates;
    mapping (address => uint256) public lastFundingTimes;

    mapping (bytes32 => Position) public positions;

    mapping (address => uint256) public feeReserves;

    event BuyUSDG(address token, uint256 tokenAmount, uint256 usdgAmount);
    event SellUSDG(address token, uint256 usdgAmount, uint256 tokenAmount);
    event Swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectSwapFees(address token, uint256 feeAmount);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseUsdgAmount(address token, uint256 amount);
    event DecreaseUsdgAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);
    event IncreaseGuaranteedUsd(address token, uint256 amount);
    event DecreaseGuaranteedUsd(address token, uint256 amount);

    modifier onlyGov() {
        require(msg.sender == gov, "Vault: forbidden");
        _;
    }

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() public {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _usdg,
        uint256 _maxUsdg,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor
    ) external onlyGov {
        require(!isInitialized, "Vault: already initialized");
        isInitialized = true;

        router = _router;
        usdg = _usdg;
        maxUsdg = _maxUsdg;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
    }

    function setGov(address _gov) external onlyGov {
        gov = _gov;
    }

    function setMaxUsdg(uint256 _maxUsdg) external nonReentrant onlyGov {
        maxUsdg = _maxUsdg;
    }

    function setMaxLeverage(uint256 _maxLeverage) external nonReentrant onlyGov {
        require(_maxLeverage > MIN_LEVERAGE, "Vault: invalid _maxLeverage");
        maxLeverage = _maxLeverage;
    }

    function setPriceSampleSpace(uint256 _priceSampleSpace) external nonReentrant onlyGov {
        require(_priceSampleSpace > 0, "Vault: invalid _priceSampleSpace");
        priceSampleSpace = _priceSampleSpace;
    }

    function setFees(
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd
    ) external nonReentrant onlyGov {
        require(_swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "Vault: invalid _swapFeeBasisPoints");
        require(_stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "Vault: invalid _stableSwapFeeBasisPoints");
        require(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "Vault: invalid _marginFeeBasisPoints");
        require(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, "Vault: invalid _liquidationFeeUsd");
        liquidationFeeUsd = _liquidationFeeUsd;
        swapFeeBasisPoints = _swapFeeBasisPoints;
        stableSwapFeeBasisPoints = _stableSwapFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
    }

    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor) external nonReentrant onlyGov {
        require(_fundingInterval > MIN_FUNDING_RATE_INTERVAL, "Vault: invalid _fundingInterval");
        require(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, "Vault: invalid _fundingRateFactor");
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
    }

    function setTokenConfig(
        address _token,
        address _priceFeed,
        uint256 _priceDecimals,
        uint256 _tokenDecimals,
        uint256 _redemptionBps,
        uint256 _minProfitBps,
        bool _isStable
    ) external nonReentrant onlyGov {
        whitelistedTokens[_token] = true;
        priceFeeds[_token] = _priceFeed;
        priceDecimals[_token] = _priceDecimals;
        tokenDecimals[_token] = _tokenDecimals;
        redemptionBasisPoints[_token] = _redemptionBps;
        minProfitBasisPoints[_token] = _minProfitBps;
        stableTokens[_token] = _isStable;

        // validate price feed
        getMaxPrice(_token);
    }

    function clearTokenConfig(address _token) external nonReentrant onlyGov {
        require(whitelistedTokens[_token], "Vault: token not whitelisted");
        delete whitelistedTokens[_token];
        delete priceFeeds[_token];
        delete priceDecimals[_token];
        delete tokenDecimals[_token];
        delete redemptionBasisPoints[_token];
        delete minProfitBasisPoints[_token];
        delete stableTokens[_token];
    }

    function withdrawFees(address _token, address _receiver) external nonReentrant onlyGov returns (uint256) {
        uint256 amount = feeReserves[_token];
        if(amount == 0) { return 0; }
        feeReserves[_token] = 0;
        _transferOut(_token, amount, _receiver);
    }

    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    function buyUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        require(whitelistedTokens[_token], "Vault: _token not whitelisted");

        uint256 tokenAmount = _transferIn(_token);
        require(tokenAmount > 0, "Vault: invalid tokenAmount");

        updateCumulativeFundingRate(_token);

        uint256 price = getMinPrice(_token);

        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, stableTokens[_token]);
        uint256 usdgAmount = amountAfterFees.mul(price).div(PRICE_PRECISION);
        usdgAmount = adjustForDecimals(usdgAmount, _token, usdg);
        require(usdgAmount > 0, "Vault: invalid usdgAmount");
        require(IERC20(usdg).totalSupply().add(usdgAmount) <= maxUsdg, "Vault: maxUsdg exceeded");

        IUSDG(usdg).mint(_receiver, usdgAmount);

        _increaseUsdgAmount(_token, usdgAmount);
        _increasePoolAmount(_token, amountAfterFees);

        emit BuyUSDG(_token, tokenAmount, usdgAmount);

        return usdgAmount;
    }

    function sellUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        require(whitelistedTokens[_token], "Vault: _token not whitelisted");

        uint256 usdgAmount = _transferIn(usdg);
        require(usdgAmount > 0, "Vault: invalid usdgAmount");

        updateCumulativeFundingRate(_token);

        uint256 redemptionAmount = getRedemptionAmount(_token, usdgAmount);
        require(redemptionAmount > 0, "Vault: invalid redemptionAmount");

        _decreaseUsdgAmount(_token, usdgAmount);
        _decreasePoolAmount(_token, redemptionAmount);

        IUSDG(usdg).burn(address(this), usdgAmount);

        uint256 tokenAmount = _collectSwapFees(_token, redemptionAmount, stableTokens[_token]);
        require(tokenAmount > 0, "Vault: invalid tokenAmount");
        _transferOut(_token, tokenAmount, _receiver);

        // the _transferIn call increased the value of tokenBalances[usdg]
        // usually decreases in token balances are synced by calling _transferOut
        // however, for usdg, the tokens are burnt, so _updateTokenBalance should
        // be manually called to record the decrease in tokens
        _updateTokenBalance(usdg);

        emit SellUSDG(_token, usdgAmount, tokenAmount);

        return tokenAmount;
    }

    function swap(address _tokenIn, address _tokenOut, address _receiver) external override nonReentrant returns (uint256) {
        require(whitelistedTokens[_tokenIn], "Vault: _tokenIn not whitelisted");
        require(whitelistedTokens[_tokenOut], "Vault: _tokenOut not whitelisted");
        updateCumulativeFundingRate(_tokenIn);
        updateCumulativeFundingRate(_tokenOut);

        uint256 amountIn = _transferIn(_tokenIn);
        require(amountIn > 0, "Vault: invalid amountIn");

        uint256 priceIn = getMinPrice(_tokenIn);
        uint256 priceOut = getMaxPrice(_tokenOut);

        uint256 amountOut = amountIn.mul(priceIn).div(priceOut);
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut);
        uint256 amountAfterFees = _collectSwapFees(_tokenOut, amountOut, stableTokens[_tokenIn] && stableTokens[_tokenOut]);

        // adjust usdgAmounts by the same usdAmount as debt is shifted between the assets
        uint256 usdAmount = amountIn.mul(priceIn).div(PRICE_PRECISION);
        uint256 usdIn = adjustForDecimals(usdAmount, _tokenIn, usdg);
        uint256 usdOut = adjustForDecimals(usdAmount, _tokenOut, usdg);

        _increaseUsdgAmount(_tokenIn, usdIn);
        _decreaseUsdgAmount(_tokenOut, usdOut);

        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOut);

        _transferOut(_tokenOut, amountAfterFees, _receiver);

        emit Swap(_tokenIn, _tokenOut, amountIn, amountAfterFees);

        return amountAfterFees;
    }

    function increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external override nonReentrant {
        _validateRouter(_account);
        _validateTokens(_collateralToken, _indexToken, _isLong);
        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta);
        }

        uint256 fee = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);
        uint256 collateralDelta = _transferIn(_collateralToken);
        uint256 collateralDeltaUsd = tokenToUsdMin(_collateralToken, collateralDelta);

        position.collateral = position.collateral.add(collateralDeltaUsd);
        require(position.collateral >= fee, "Vault: insufficient collateral for fees");

        position.collateral = position.collateral.sub(fee);
        position.entryFundingRate = cumulativeFundingRates[_collateralToken];
        position.size = position.size.add(_sizeDelta);

        require(position.size > 0, "Vault: invalid position.size");
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount = position.reserveAmount.add(reserveDelta);
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            // add the fee as it has been subtracted from the collateral
            _increaseGuaranteedUsd(_collateralToken, _sizeDelta.add(fee));
            _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(_collateralToken, collateralDelta);
            // fees need to be deducted from the pool since collateral is treated as part of the pool
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, fee));
        }

        emit IncreasePosition(key, _account, _collateralToken, _indexToken, collateralDeltaUsd, _sizeDelta, _isLong);
        emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount);
    }

    function decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external override nonReentrant returns (uint256) {
        _validateRouter(_account);
        _validateTokens(_collateralToken, _indexToken, _isLong);
        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");
        require(position.size >= _sizeDelta, "Vault: position size exceeded");

        uint256 collateral = position.collateral;
        // scrop variables to avoid stack too deep errors
        {
        uint256 reserveDelta = position.reserveAmount.mul(_sizeDelta).div(position.size);
        position.reserveAmount = position.reserveAmount.sub(reserveDelta);
        _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);

        if (position.size != _sizeDelta) {
            position.entryFundingRate = cumulativeFundingRates[_collateralToken];
            position.size = position.size.sub(_sizeDelta);

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral.sub(position.collateral));
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);
            emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount);
        } else {
            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral);
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }
            delete positions[key];
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);
            emit ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount);
        }


        if (usdOut > 0) {
            if (_isLong) {
                _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, usdOut));
            }
            uint256 amountOutAfterFees = usdToTokenMin(_collateralToken, usdOutAfterFee);
            _transferOut(_collateralToken, usdToTokenMin(_collateralToken, usdOutAfterFee), _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    function liquidatePosition(address _account, address _collateralToken, address _indexToken, bool _isLong, address _feeReceiver) external nonReentrant {
        _validateTokens(_collateralToken, _indexToken, _isLong);
        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        require(position.size > 0, "Vault: empty position");

        (bool _shouldLiquidate, uint256 marginFees) = validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        require(_shouldLiquidate, "Vault: position cannot be liquidated");

        feeReserves[_collateralToken] = feeReserves[_collateralToken].add(usdToTokenMin(_collateralToken, marginFees));

        _decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            _decreaseGuaranteedUsd(_collateralToken, position.size.sub(position.collateral));
        }

        emit LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount);

        delete positions[key];

        if (!_isLong && marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral.sub(marginFees);
            _increasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, remainingCollateral));
        }

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd));
        _transferOut(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd), _feeReceiver);
    }

    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];

        (bool hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong);
        uint256 marginFees = getFundingFee(_collateralToken, position.size, position.entryFundingRate);
        marginFees = marginFees.add(getPositionFee(position.size));

        if (!hasProfit && position.collateral < delta) {
            if (_raise) { revert("Vault: losses exceed collateral"); }
            return (true, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral.sub(delta);
        }

        if (remainingCollateral < marginFees) {
            if (_raise) { revert("Vault: fees exceed collateral"); }
            // cap the fees to the remainingCollateral
            return (true, remainingCollateral);
        }

        if (remainingCollateral < marginFees.add(liquidationFeeUsd)) {
            if (_raise) { revert("Vault: liquidation fees exceed collateral"); }
            return (true, marginFees);
        }

        if (remainingCollateral.mul(maxLeverage) < position.size.mul(BASIS_POINTS_DIVISOR)) {
            if (_raise) { revert("Vault: maxLeverage exceeded"); }
            return (true, marginFees);
        }

        return (false, marginFees);
    }

    function getMaxPrice(address _token) public override view returns (uint256) {
        return getPrice(_token, true);
    }

    function getMinPrice(address _token) public override view returns (uint256) {
        return getPrice(_token, false);
    }

    function getSinglePrice(address _token) public override view returns (uint256) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Vault: invalid price feed");
        return uint256(IPriceFeed(priceFeedAddress).latestAnswer());
    }

    function getRoundId(address _token) public override view returns (uint256) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Vault: invalid price feed");
        return uint256(IPriceFeed(priceFeedAddress).latestRound());
    }

    function getRoundPrice(address _token, uint256 _roundId) public override view returns (uint256) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Vault: invalid price feed");
        require(_roundId < type(uint80).max, "Vault: invalid _roundId");
        (, int256 p, , ,) = IPriceFeed(priceFeedAddress).getRoundData(uint80(_roundId));
        return uint256(p);
    }

    function getPrice(address _token, bool _maximise) public view returns (uint256) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Vault: invalid price feed");
        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);

        uint256 price = 0;
        uint80 roundId = priceFeed.latestRound();

        for (uint80 i = 0; i < priceSampleSpace; i++) {
            if (roundId < i) { break; }
            if (roundId - i == 0) { continue; }
            (, int256 p, , ,) = priceFeed.getRoundData(roundId - i);
            require(p > 0, "Vault: invalid price");

            if (price == 0) {
                price = uint256(p);
                continue;
            }

            if (_maximise && uint256(p) > price) {
                price = uint256(p);
            }

            if (!_maximise && uint256(p) < price) {
                price = uint256(p);
            }
        }

        require(price > 0, "Vault: could not fetch price");
        // normalise price precision
        return price.mul(PRICE_PRECISION).div(getPricePrecision(_token));
    }

    function getPricePrecision(address _token) public view returns (uint256) {
        uint256 decimals = priceDecimals[_token];
        return 10 ** decimals;
    }

    function getRedemptionAmount(address _token, uint256 _usdgAmount) public override view returns (uint256) {
        uint256 price = getMaxPrice(_token);
        // calculate the price based redemption amount
        uint256 redemptionAmount = _usdgAmount.mul(PRICE_PRECISION).div(price);

        if (stableTokens[_token]) {
            return redemptionAmount;
        }

        uint256 redemptionCollateral = getRedemptionCollateral(_token);
        if (redemptionCollateral == 0) { return 0; }

        uint256 totalUsdgAmount = usdgAmounts[_token];

        // if there is no USDG debt then the redemption amount based just on price can be supported
        if (totalUsdgAmount == 0) {
            return redemptionAmount;
        }

        // calculate the cappedAmount based on the amount of backing collateral and the
        // total debt in USDG tokens for the asset
        uint256 cappedAmount = _usdgAmount.mul(redemptionCollateral).div(totalUsdgAmount);
        uint256 basisPoints = getRedemptionBasisPoints(_token);
        cappedAmount = cappedAmount.mul(basisPoints).div(BASIS_POINTS_DIVISOR);
        cappedAmount = adjustForDecimals(cappedAmount, usdg, _token);

        return cappedAmount < redemptionAmount ? cappedAmount : redemptionAmount;
    }

    function getRedemptionCollateral(address _token) public view returns (uint256) {
        if (stableTokens[_token]) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        return collateral.add(poolAmounts[_token]).sub(reservedAmounts[_token]);
    }

    function getRedemptionCollateralUsd(address _token) public view returns (uint256) {
        return tokenToUsdMin(_token, getRedemptionCollateral(_token));
    }

    function getRedemptionBasisPoints(address _token) public view returns (uint256) {
        uint256 basisPoints = redemptionBasisPoints[_token];
        require(basisPoints > 0, "Vault: invalid redemption basis points");
        return basisPoints;
    }

    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdg ? USDG_DECIMALS : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdg ? USDG_DECIMALS : tokenDecimals[_tokenMul];
        return _amount.mul(10 ** decimalsMul).div(10 ** decimalsDiv);
    }

    function availableReserve(address _token) public view returns (uint256) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        return balance.sub(reservedAmounts[_token]);
    }

    function tokenToUsdMax(address _token, uint256 _tokenAmount) public view returns (uint256) {
        if (_tokenAmount == 0) { return 0; }
        uint256 price = getMaxPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return _tokenAmount.mul(price).div(10 ** decimals);
    }

    function tokenToUsdMin(address _token, uint256 _tokenAmount) public view returns (uint256) {
        if (_tokenAmount == 0) { return 0; }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return _tokenAmount.mul(price).div(10 ** decimals);
    }

    function usdToTokenMax(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    function usdToTokenMin(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        uint256 decimals = tokenDecimals[_token];
        return _usdAmount.mul(10 ** decimals).div(_price);
    }

    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(-position.realisedPnl);
        return (position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, realisedPnl, position.realisedPnl >= 0);
    }

    function getPositionKey(address _account, address _collateralToken, address _indexToken, bool _isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        ));
    }

    function updateCumulativeFundingRate(address _token) public {
        if (lastFundingTimes[_token] == 0) {
            lastFundingTimes[_token] = block.timestamp.div(fundingInterval).mul(fundingInterval);
            return;
        }

        if (lastFundingTimes[_token].add(fundingInterval) > block.timestamp) {
            return;
        }

        uint256 fundingRate = getNextFundingRate(_token);
        cumulativeFundingRates[_token] = cumulativeFundingRates[_token].add(fundingRate);
        lastFundingTimes[_token] = block.timestamp.div(fundingInterval).mul(fundingInterval);

        emit UpdateFundingRate(_token, cumulativeFundingRates[_token]);
    }

    function getNextFundingRate(address _token) public override view returns (uint256) {
        if (lastFundingTimes[_token].add(fundingInterval) > block.timestamp) { return 0; }

        uint256 intervals = block.timestamp.sub(lastFundingTimes[_token]).div(fundingInterval);
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        return fundingRateFactor.mul(reservedAmounts[_token]).mul(intervals).div(poolAmount);
    }

    function getUtilisation(address _token) public view returns (uint256) {
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        return reservedAmounts[_token].mul(FUNDING_RATE_PRECISION).div(poolAmount);
    }

    function getPositionLeverage(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        require(position.collateral > 0, "Vault: invalid position");
        return position.size.mul(BASIS_POINTS_DIVISOR).div(position.collateral);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (delta + nextSize)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextAveragePrice(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _nextPrice, uint256 _sizeDelta) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong);
        uint256 nextSize = _size.add(_sizeDelta);
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }
        return _nextPrice.mul(nextSize).div(divisor);
    }

    function getPositionDelta(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong);
    }

    function getDelta(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong) public override view returns (bool, uint256) {
        require(_averagePrice > 0, "Vault: invalid _averagePrice");
        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price ? _averagePrice.sub(price) : price.sub(_averagePrice);
        uint256 delta = _size.mul(priceDelta).div(_averagePrice);

        bool hasProfit;

        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        // the profit is zero-ed out if the minimum % of profit is not reached
        // this helps to prevent front-running issues
        uint256 minBps = minProfitBasisPoints[_indexToken];
        if (hasProfit && delta.mul(BASIS_POINTS_DIVISOR) <= _size.mul(minBps)) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function getFundingFee(address _token, uint256 _size, uint256 _entryFundingRate) public view returns (uint256) {
        if (_size == 0) { return 0; }

        uint256 fundingRate = cumulativeFundingRates[_token].sub(_entryFundingRate);
        if (fundingRate == 0) { return 0; }

        uint256 fundingFee = _size.mul(fundingRate).div(FUNDING_RATE_PRECISION);
        return fundingFee;
    }

    function getPositionFee(uint256 _sizeDelta) public view returns (uint256) {
        if (_sizeDelta == 0) { return 0; }
        uint256 afterFeeUsd = _sizeDelta.mul(BASIS_POINTS_DIVISOR.sub(marginFeeBasisPoints)).div(BASIS_POINTS_DIVISOR);
        return _sizeDelta.sub(afterFeeUsd);
    }

    function _reduceCollateral(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
        (bool _hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong);
        hasProfit = _hasProfit;
        // get the proportional change in pnl
        adjustedDelta = _sizeDelta.mul(delta).div(position.size);
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral.sub(adjustedDelta);

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _increasePoolAmount(_collateralToken, tokenAmount);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut.add(_collateralDelta);
            position.collateral = position.collateral.sub(_collateralDelta);
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut = usdOut.add(position.collateral);
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut.sub(fee);
        } else {
            position.collateral = position.collateral.sub(fee);
            if (_isLong) {
                uint256 feeTokens = usdToTokenMin(_collateralToken, fee);
                _decreasePoolAmount(_collateralToken, feeTokens);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function _validatePosition(uint256 _size, uint256 _collateral) private pure {
        if (_size == 0) {
            require(_collateral == 0, "Vault: collateral should be withdrawn");
            return;
        }
        require(_size >= _collateral, "Vault: _size must be more than _collateral");
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) { return; }
        if (msg.sender == router) { return; }
        require(approvedRouters[_account][msg.sender], "Vault: invalid msg.sender");
    }

    function _validateTokens(address _collateralToken, address _indexToken, bool _isLong) private view {
        if (_isLong) {
            require(_collateralToken == _indexToken, "Vault: mismatched tokens");
            require(whitelistedTokens[_collateralToken], "Vault: _collateralToken not whitelisted");
            require(!stableTokens[_collateralToken], "Vault: _collateralToken must not be a stableToken");
            return;
        }

        // _indexToken is intentionally not enforced to be a whitelisted token for shorts
        // it just needs to have a valid priceFeed
        // this adds flexbility by allowing shorting on non-whitelisted tokens
        require(whitelistedTokens[_collateralToken], "Vault: _collateralToken not whitelisted");
        require(stableTokens[_collateralToken], "Vault: _collateralToken must be a stableToken");
        require(!stableTokens[_indexToken], "Vault: _indexToken must not be a stableToken");
    }

    function _collectSwapFees(address _token, uint256 _amount, bool _isStableSwap) private returns (uint256) {
        uint256 feeBasisPoints = _isStableSwap ? stableSwapFeeBasisPoints : swapFeeBasisPoints;
        uint256 afterFeeAmount = _amount.mul(BASIS_POINTS_DIVISOR.sub(feeBasisPoints)).div(BASIS_POINTS_DIVISOR);
        uint256 feeAmount = _amount.sub(afterFeeAmount);
        feeReserves[_token] = feeReserves[_token].add(feeAmount);
        emit CollectSwapFees(_token, feeAmount);
        return afterFeeAmount;
    }

    function _collectMarginFees(address _token, uint256 _sizeDelta, uint256 _size, uint256 _entryFundingRate) private returns (uint256) {
        uint256 feeUsd = getPositionFee(_sizeDelta);

        uint256 fundingFee = getFundingFee(_token, _size, _entryFundingRate);
        feeUsd = feeUsd.add(fundingFee);

        uint256 feeTokens = usdToTokenMin(_token, feeUsd);
        feeReserves[_token] = feeReserves[_token].add(feeTokens);

        emit CollectMarginFees(_token, feeUsd, feeTokens);
        return feeUsd;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance.sub(prevBalance);
    }

    function _transferOut(address _token, uint256 _amount, address _receiver) private {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    }

    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].add(_amount);
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(poolAmounts[_token] <= balance, "Vault: invalid increase");
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].sub(_amount, "Vault: poolAmount exceeded");
        require(reservedAmounts[_token] <= poolAmounts[_token], "Vault: reserve exceeds pool");
        emit DecreasePoolAmount(_token, _amount);
    }

    function _increaseUsdgAmount(address _token, uint256 _amount) private {
        usdgAmounts[_token] = usdgAmounts[_token].add(_amount);
        emit IncreaseUsdgAmount(_token, _amount);
    }

    function _decreaseUsdgAmount(address _token, uint256 _amount) private {
        uint256 value = usdgAmounts[_token];
        // since USDG can be minted using multiple assets
        // it is possible for the USDG debt for a single asset to be less than zero
        // the USDG debt is capped to zero for this case
        if (value <= _amount) {
            usdgAmounts[_token] = 0;
            emit DecreaseUsdgAmount(_token, value);
            return;
        }
        usdgAmounts[_token] = value.sub(_amount);
        emit DecreaseUsdgAmount(_token, _amount);
    }

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].add(_amount);
        require(reservedAmounts[_token] <= poolAmounts[_token], "Vault: reserve exceeds pool");
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].sub(_amount, "Vault: insufficient reserve");
        emit DecreaseReservedAmount(_token, _amount);
    }

    function _increaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].add(_usdAmount);
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].sub(_usdAmount);
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }
}
