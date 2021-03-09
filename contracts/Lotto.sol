//SPDX-License-Identifier: MIT
pragma solidity >0.6.0;
pragma experimental ABIEncoderV2;
// Imported OZ helper contracts
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
// Inherited allowing for ownership of contract
import "@openzeppelin/contracts/access/Ownable.sol";
// Allows for intergration with ChainLink VRF
import "./RandomNumberGenerator.sol";
// Interface for Lottery NFT to mint tokens
import "./ILottoNFT.sol";
// Allows for time manipulation. Set to 0x address on test/mainnet deploy
import "./Testable.sol";

import "./Strings.sol";

// TODO rename to Lottery when done
contract Lotto is Ownable, Testable {
    // Libraries 
    // Counter for lottery IDs 
    using Counters for Counters.Counter;
    Counters.Counter private lotteryIDCounter_;
    // Safe math
    using SafeMath for uint256;
    using SafeMath for uint16;
    using SafeMath for uint8;
    // Safe ERC20
    using SafeERC20 for IERC20;

    using Strings for string;

    // State variables 
    // Instance of Cake token (collateral currency for lotto)
    IERC20 internal cake_;
    // Storing of the NFT
    ILottoNFT internal nft_;
    // Storing of the randomness generator 
    RandomNumberGenerator internal randomGenerator_;
    bytes32 internal requestId_;

    // Lottery size
    uint8 public sizeOfLottery_;
    // Max range for numbers (starting at 0)
    uint16 public maxValidRange_;

    // Represents the status of the lottery
    enum Status { 
        NotStarted,     // The lottery has not started yet
        Open,           // The lottery is open for ticket purchases 
        Closed,         // The lottery is no longer open for ticket purchases
        Completed       // The lottery has been closed and the numbers drawn
    }
    // All the needed info around a lottery
    struct LottoInfo {
        uint256 lotteryID;          // ID for lotto
        Status lotteryStatus;       // Status for lotto
        uint256 prizePoolInCake;    // The amount of cake for prize money
        uint256 costPerTicket;      // Cost per ticket in $cake
        uint8[] prizeDistribution;  // The distribution for prize money
        uint256 startingTimestamp;      // Block timestamp for star of lotto
        uint256 closingTimestamp;       // Block timestamp for end of entries
        uint256 endTimestamp;           // Block timestamp for claiming winnings
        uint16[] winningNumbers;     // The winning numbers
    }
    // Lottery ID's to info
    mapping(uint256 => LottoInfo) internal allLotteries_;

    //-------------------------------------------------------------------------
    // EVENTS
    //-------------------------------------------------------------------------

    event NewLotteryCreated(
        uint256 indexed lotteryId,
        Status lotteryStatus,
        uint8[] prizeDistribution,
        uint256 prizePoolInCake,
        uint256 costPerTicket,
        uint256 startingTimestamp,
        uint256 closingTimestamp,
        uint256 endTimestamp,
        address indexed creator
    );

    event NewBatchMint(
        address indexed minter,
        uint256[] ticketIDs,
        uint16[] numbers,
        uint256 totalCost,
        uint256 discount,
        uint256 pricePaid
    );

    event requestNumbers(uint256 lotteryId, bytes32 requestId);

    //-------------------------------------------------------------------------
    // MODIFIERS
    //-------------------------------------------------------------------------

    modifier onlyRandomGenerator() {
        require(
            msg.sender == address(randomGenerator_),
            "Only random generator"
        );
        _;
    }

    //-------------------------------------------------------------------------
    // CONSTRUCTOR
    //-------------------------------------------------------------------------

    constructor(
        address _cake, 
        address _timer,
        uint8 _sizeOfLotteryNumbers,
        uint16 _maxValidNumberRange,
        address _randomNumberGenerator
    ) 
        Testable(_timer)
        public
    {
        cake_ = IERC20(_cake);
        sizeOfLottery_ = _sizeOfLotteryNumbers;
        maxValidRange_ = _maxValidNumberRange;
        randomGenerator_ = RandomNumberGenerator(_randomNumberGenerator);
    }

    function init(address _lotteryNFT) external onlyOwner() {
        nft_ = ILottoNFT(_lotteryNFT);
    }

    //-------------------------------------------------------------------------
    // VIEW FUNCTIONS
    //-------------------------------------------------------------------------

    function costToBuyTickets(
        uint256 _lotteryID,
        uint256 _numberOfTickets
    ) 
        external 
        view 
        returns(uint256 totalCost) 
    {
        uint256 pricePer = allLotteries_[_lotteryID].costPerTicket;
        totalCost = pricePer.mul(_numberOfTickets);
    }

    function getBasicLottoInfo(uint256 _lotteryID) external view returns(
        LottoInfo memory
    )
    {
        return(
            allLotteries_[_lotteryID]
        ); 
    }

    function getMaxRange() external view returns(uint16) {
        return maxValidRange_;
    }

    //-------------------------------------------------------------------------
    // STATE MODIFYING FUNCTIONS 
    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Restricted Access Functions (onlyOwner)

    function updateSizeOfLottery(uint8 _newSize) external onlyOwner() {
        require(
            sizeOfLottery_ != _newSize,
            "Cannot set to current size"
        );
        sizeOfLottery_ = _newSize;
    }

    function updateMaxRange(uint16 _newMaxRange) external onlyOwner() {
        require(
            maxValidRange_ != _newMaxRange,
            "Cannot set to current size"
        );
        maxValidRange_ = _newMaxRange;
    }


    function drawWinningNumbers(
        uint256 _lotteryId, 
        uint256 _seed
    ) 
        external 
        onlyOwner() 
    {
        // Checks that the lottery is past the closing block
        require(
            allLotteries_[_lotteryId].closingTimestamp <= getCurrentTime(),
            "Cannot set winning numbers during lottery"
        );
        // Checks lottery numbers have not already been drawn
        require(
            allLotteries_[_lotteryId].lotteryStatus != Status.Closed,
            "Winning Numbers drawn"
        );
        // Sets lottery status to closed
        allLotteries_[_lotteryId].lotteryStatus = Status.Closed;
        // Requests a random number from the generator
        requestId_ = randomGenerator_.getRandomNumber(_lotteryId, _seed);
        // Emits that random number has been requested
        emit requestNumbers(_lotteryId, requestId_);
    }

    function numbersDrawn(
        uint256 _lotteryId,
        bytes32 _requestId, 
        uint256 _randomNumber
    ) 
        external
        onlyRandomGenerator()
    {
        require(
            allLotteries_[_lotteryId].lotteryStatus == Status.Closed,
            "Draw numbers first"
        );
        if(requestId_ == _requestId) {
            allLotteries_[_lotteryId].lotteryStatus = Status.Completed;
            allLotteries_[_lotteryId].winningNumbers = split(_randomNumber);
        }
    }

    /**
     * @param   _prizeDistribution An array defining the distribution of the 
     *          prize pool. I.e if a lotto has 5 numbers, the distribution could
     *          be [5, 10, 15, 20, 30] = 100%. This means if you get one number
     *          right you get 5% of the pool, 2 matching would be 10% and so on.
     * @param   _prizePoolInCake The amount of Cake available to win in this 
     *          lottery.
     * @param   _startingTimestamp The block timestamp for the beginning of the 
     *          lottery. 
     * @param   _closingTimestamp The block timestamp after which no more tickets
     *          will be sold for the lottery. Note that this timestamp MUST
     *          be after the starting block timestamp. 
     * @param   _endTimestamp The block timestamp for the end of the lottery. After
     *          this time users can withdraw any winnings. Note that between
     *          the closing block and this end block the winning numbers must
     *          be added by the admin. If they are not this end block timestamp
     *          will be pushed back until winning numbers are added. 
     */
    function createNewLotto(
        uint8[] calldata _prizeDistribution,
        uint256 _prizePoolInCake,
        uint256 _costPerTicket,
        uint256 _startingTimestamp,
        uint256 _closingTimestamp,
        uint256 _endTimestamp
    )
        external
        onlyOwner()
        returns(uint256 lotteryId)
    {
        require(
            _prizeDistribution.length == sizeOfLottery_,
            "Invalid distribution"
        );
        uint256 prizeDistributionTotal = 0;
        for (uint256 j = 0; j < _prizeDistribution.length; j += 1) {
            prizeDistributionTotal = prizeDistributionTotal.add(
                uint256(_prizeDistribution[j])
            );
        }
        // Ensuring that prize distribution total is 100%
        require(
            prizeDistributionTotal == 100,
            "Prize distribution is not 100%"
        );
        require(
            _prizePoolInCake != 0 && _costPerTicket != 0,
            "Prize or cost cannot be 0"
        );
        require(
            _startingTimestamp != 0 &&
            _startingTimestamp < _closingTimestamp &&
            _closingTimestamp < _endTimestamp,
            "Timestamps for lottery invalid"
        );
        // Incrementing lottery ID 
        lotteryIDCounter_.increment();
        lotteryId = lotteryIDCounter_.current();
        uint16[] memory winningNumbers = new uint16[](sizeOfLottery_);
        // Saving data in struct
        LottoInfo memory newLottery = LottoInfo(
            lotteryId,
            Status.NotStarted,
            _prizePoolInCake,
            _costPerTicket,
            _prizeDistribution,
            _startingTimestamp,
            _closingTimestamp,
            _endTimestamp,
            winningNumbers
        );
        allLotteries_[lotteryId] = newLottery;

        // Emitting important information around new lottery.
        emit NewLotteryCreated(
            lotteryId,
            Status.NotStarted,
            _prizeDistribution,
            _prizePoolInCake,
            _costPerTicket,
            _startingTimestamp,
            _closingTimestamp,
            _endTimestamp,
            msg.sender
        );
    }

    function withdrawCake() external onlyOwner() {
        cake_.transfer(
            msg.sender, 
            cake_.balanceOf(address(this))
        );
    }

    //-------------------------------------------------------------------------
    // General Access Functions

    function batchBuyLottoTicket(
        uint256 _lotteryID,
        uint8 _numberOfTickets,
        uint16[] calldata _chosenNumbersForEachTicket
    )
        external
        returns(uint256[] memory)
    {
        require(
            getCurrentTime() >= allLotteries_[_lotteryID].startingTimestamp,
            "Invalid time for mint:start"
        );
        require(
            getCurrentTime() < allLotteries_[_lotteryID].closingTimestamp,
            "Invalid time for mint:end"
        );
        uint256 numberCheck = _numberOfTickets*sizeOfLottery_;
        require(
            _chosenNumbersForEachTicket.length == numberCheck,
            "Invalid chosen numbers"
        );
        // Gets the cost per ticket
        uint256 costPerTicket = allLotteries_[_lotteryID].costPerTicket;
        // TODO make this a function including the discount 
        // Gets the total cost for the buy
        uint256 totalCost = costPerTicket*_numberOfTickets;
        // Transfers the required cake to this contract
        cake_.transferFrom(
            msg.sender, 
            address(this), 
            totalCost
        );
        // Batch mints the user their tickets
        uint256[] memory ticketIds = nft_.batchMint(
            msg.sender,
            _lotteryID,
            _numberOfTickets,
            _chosenNumbersForEachTicket,
            sizeOfLottery_
        );
        // Emitting event with all information
        emit NewBatchMint(
            msg.sender,
            ticketIds,
            _chosenNumbersForEachTicket,
            totalCost,
            0, // TODO
            totalCost
        );
        return ticketIds;
    }


    function claimReward(uint256 _lotteryId, uint256 _tokenId) external {
        // Checking the lottery is in a valid time for claiming
        require(
            allLotteries_[_lotteryId].endTimestamp <= getCurrentTime(),
            "Wait till end to claim"
        );
        // Checks the lottery winning numbers are available 
        require(
            allLotteries_[_lotteryId].lotteryStatus == Status.Completed,
            "Winning Numbers not chosen yet"
        );
        require(
            nft_.getOwnerOfTicket(_tokenId) == msg.sender,
            "Only the owner can claim"
        );
        // Sets the claim of the ticket to true (if claimed, will revert)
        require(
            nft_.claimTicket(_tokenId),
            "Numbers for ticket invalid"
        );
        // Getting the number of matching tickets
        uint8 matchingNumbers = getNumberOfMatching(
            nft_.getTicketNumbers(_tokenId),
            allLotteries_[_lotteryId].winningNumbers
        );
        // Getting the prize amount for those matching tickets
        uint256 prizeAmount = prizeForMatching(
            matchingNumbers,
            _lotteryId
        );
        // Removing the prize amount from the pool
        allLotteries_[_lotteryId].prizePoolInCake = allLotteries_[_lotteryId].prizePoolInCake.sub(prizeAmount);
        // Transfering the user their winnings
        cake_.safeTransfer(address(msg.sender), prizeAmount);
    }

    function batchClaimRewards(
        uint256 _lotteryID, 
        uint256[] calldata _tokeIDs
    ) external {
        // Checking the lottery is in a valid time for claiming
        require(
            allLotteries_[_lotteryID].endTimestamp <= getCurrentTime(),
            "Wait till end to claim"
        );
        // Checks the lottery winning numbers are available 
        require(
            allLotteries_[_lotteryID].lotteryStatus == Status.Completed,
            "Winning Numbers not chosen yet"
        );
        // Creates a storage for all winnings
        uint256 totalPrize = 0;
        // Loops through each submitted token
        for (uint256 i = 0; i < _tokeIDs.length; i++) {
            // Checks user is owner (will revert entire call if not)
            require(
                nft_.getOwnerOfTicket(_tokeIDs[i]) == msg.sender,
                "Only the owner can claim"
            );
            // If token has already been claimed, skip token
            if(
                nft_.getTicketClaimStatus(_tokeIDs[i])
            ) {
                continue;
            }
            // Claims the ticket (will only revert if numbers invalid)
            require(
                nft_.claimTicket(_tokeIDs[i]),
                "Numbers for ticket invalid"
            );
            // Getting the number of matching tickets
            uint8 matchingNumbers = getNumberOfMatching(
                nft_.getTicketNumbers(_tokeIDs[i]),
                allLotteries_[_lotteryID].winningNumbers
            );
            // Getting the prize amount for those matching tickets
            uint256 prizeAmount = prizeForMatching(
                matchingNumbers,
                _lotteryID
            );
            // Removing the prize amount from the pool
            allLotteries_[_lotteryID].prizePoolInCake = allLotteries_[_lotteryID].prizePoolInCake.sub(prizeAmount);
            totalPrize = totalPrize.add(prizeAmount);
        }
        // Transferring the user their winnings
        cake_.safeTransfer(address(msg.sender), totalPrize);
    }

    //-------------------------------------------------------------------------
    // INTERNAL FUNCTIONS 
    //-------------------------------------------------------------------------

    function getNumberOfMatching(
        uint16[] memory _usersNumbers, 
        uint16[] memory _winningNumbers
    )
        internal
        pure
        returns(uint8)
    {
        uint8 noOfMatching = 0;

        for (uint256 i = 0; i < _winningNumbers.length; i++) {
            if(_usersNumbers[i] == _winningNumbers[i]) {
                noOfMatching += 1;
            }
        }

        return noOfMatching;
    }

    /**
     * @param   _noOfMatching: The number of matching numbers the user has
     * @param   _lotteryID: The ID of the lottery the user is claiming on
     * @return  uint256: The prize amount in cake the user is entitled to 
     */
    function prizeForMatching(
        uint8 _noOfMatching,
        uint256 _lotteryID
    ) 
        internal  
        view
        returns(uint256) 
    {
        uint256 prize = 0;
        // If user has no matching numbers their prize is 0
        if(_noOfMatching == 0) {
            return 0;
        } 
        // Getting the percentage of the pool the user has won
        uint256 perOfPool = allLotteries_[_lotteryID].prizeDistribution[_noOfMatching-1];
        // Timesing the percentage one by the pool
        prize = allLotteries_[_lotteryID].prizePoolInCake*perOfPool;
        // Returning the prize divided by 100 (as the prize distribution is scaled)
        return prize/100;
    }

    function split(
        uint256 _randomNumber
    ) 
        public 
        view 
        returns(uint16[] memory) 
    {


        if(maxValidRange_ < 100) {

        }
        uint256 position = 10;
        uint256 previousPosition = 10;
        uint256 number = 0;
        uint16[] memory winningNumbers = new uint16[](sizeOfLottery_);
        for (uint256 i = 0; i < sizeOfLottery_; i++) {
            if(i == 0) {
                number = _randomNumber % position;
                position = uint256(10).mul(position);
            } else {
                number = _randomNumber % position / previousPosition;
                previousPosition = position;
                position = uint256(10).mul(position);
            }
            winningNumbers[i] = uint16(number);
        }
        return winningNumbers;
    }
}
