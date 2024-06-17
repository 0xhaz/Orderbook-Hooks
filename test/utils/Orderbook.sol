// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {IOrderbook} from "./IOrderbook.sol";
import {Initializable} from "./Initializable.sol";
import {TransferHelper} from "./TransferHelper.sol";
import {ExchangeLinkedList} from "./ExchangeLinkedList.sol";
import {ExchangeOrderbook} from "./ExchangeOrderbook.sol";

interface IWETHMinimal {
    function WETH() external view returns (address);
    function transfer(address to, uint256 value) external returns (bool);
    function withdraw(uint256) external;
}

contract Orderbook is IOrderbook, Initializable {
    using ExchangeLinkedList for ExchangeLinkedList.PriceLinkedList;
    using ExchangeOrderbook for ExchangeOrderbook.OrderStorage;

    // Pair Struct
    struct Pair {
        uint256 id;
        address base;
        address quote;
        address engine;
    }

    Pair private pair;

    uint64 private decDiff;
    bool private baseBquote;

    ExchangeLinkedList.PriceLinkedList private priceLists;
    ExchangeOrderbook.OrderStorage private _askOrders;
    ExchangeOrderbook.OrderStorage private _bidOrders;

    error InvalidDecimals(uint8 base, uint8 quote);
    error InvalidAccess(address sender, address allowed);
    error PriceIsZero(uint256 price);

    function initialize(uint256 id_, address base_, address quote_, address engine_) external initializer {
        uint8 baseD = TransferHelper.decimals(base_);
        uint8 quoteD = TransferHelper.decimals(quote_);
        if (baseD > 18 || quoteD > 18) {
            revert InvalidDecimals(baseD, quoteD);
        }
        (uint8 diff, bool baseBquote_) = _absdiff(baseD, quoteD);
        decDiff = uint64(10 ** diff);
        baseBquote = baseBquote_;
        pair = Pair(id_, base_, quote_, engine_);
    }

    modifier onlyEngine() {
        if (msg.sender != pair.engine) {
            revert InvalidAccess(msg.sender, pair.engine);
        }
        _;
    }

    function setLmp(uint256 price) external onlyEngine {
        if (price == 0) revert PriceIsZero(price);
        priceLists._setLmp(price);
    }

    function placeAsk(address owner, uint256 price, uint256 amount) external onlyEngine returns (uint32 id) {
        // clear empty head
        clearEmptyHead(false);
        id = _askOrders._createOrder(owner, price, amount);
        // check if the price is new in the list. If not, insert id to the list
        if (_askOrders._isEmpty(price)) {
            priceLists._insert(false, price);
        }
        _askOrders._insertId(price, id, amount);
        return id;
    }

    function placeBid(address owner, uint256 price, uint256 amount) external onlyEngine returns (uint32 id) {
        // clear empty head
        clearEmptyHead(true);
        id = _bidOrders._createOrder(owner, price, amount);
        //
        if (_bidOrders._isEmpty(price)) {
            priceLists._insert(true, price);
        }
        _bidOrders._insertId(price, id, amount);
        return id;
    }

    function cancelOrder(bool isBid, uint32 orderId, address owner) external onlyEngine returns (uint256 remaining) {
        // check order owner
        ExchangeOrderbook.Order memory order = isBid ? _bidOrders._getOrder(orderId) : _askOrders._getOrder(orderId);

        // check before the price had an order not being empty
        bool wasEmpty = isEmpty(isBid, order.price);

        if (order.owner != owner) {
            revert InvalidAccess(owner, order.owner);
        }

        uint256 deletePrice = isBid ? _bidOrders._deleteOrder(orderId) : _askOrders._deleteOrder(orderId);
        isBid ? _sendFunds(pair.quote, owner, order.depositAmount) : _sendFunds(pair.base, owner, order.depositAmount);

        // Check if canceled order was the only one order in the list
        if (!wasEmpty && deletePrice != 0) {
            priceLists._delete(isBid, order.price);
        }

        return (order.depositAmount);
    }

    function execute(uint32 orderId, bool isBid, address sender, uint256 amount, bool clear)
        external
        onlyEngine
        returns (address owner)
    {
        ExchangeOrderbook.Order memory order = isBid ? _bidOrders._getOrder(orderId) : _askOrders._getOrder(orderId);
        uint256 converted = convert(order.price, amount, isBid);
        uint256 dust = convert(order.price, 1, isBid);
        // if isBid == true, sender is matching ask order with bit order(i.e selling base to receive quote), otherwise sender is matching bid order with ask order(i.e buying base with quote)
        if (isBid) {
            // decrease remaining amount of order
            (uint256 withDust, uint256 deletePrice) = _bidOrders._decreaseOrder(orderId, converted, dust, clear);
            // sender is matching ask order for base asset with quote asset
            _sendFunds(pair.base, order.owner, amount);
            // send converted amount of quote asset from owner to sender
            _sendFunds(pair.quote, sender, withDust);
            // delete price if price of the order is empty
            if (deletePrice != 0) {
                priceLists._delete(isBid, deletePrice);
            }
        }
        // if the order is bid order on the base/quote pair
        else {
            // decrease remaining amount of order
            (uint256 withDust, uint256 deletePrice) = _askOrders._decreaseOrder(orderId, converted, dust, clear);
            // sender is matching bid order for quote asset with base asset
            // send deposited amount of qutoe asset from sender to owner
            _sendFunds(pair.quote, order.owner, amount);
            // send converted amount of base asset from owner to sender
            _sendFunds(pair.base, sender, withDust);
            // delete price if price of the order is empty
            if (deletePrice != 0) {
                priceLists._delete(isBid, deletePrice);
            }
        }
        return order.owner;
    }

    function clearEmptyHead(bool isBid) public returns (uint256 head) {
        head = isBid ? priceLists._bidHead() : priceLists._askHead();
        uint32 orderId = isBid ? _bidOrders._head(head) : _askOrders._head(head);
        while (orderId == 0 && head != 0) {
            orderId = isBid ? _bidOrders._head(head) : _askOrders._head(head);
            if (orderId == 0) {
                head = priceLists._clearHead(isBid);
            }
        }
        return head;
    }

    function fpop(bool isBid, uint256 price, uint256 remaining)
        external
        onlyEngine
        returns (uint32 orderId, uint256 required, bool clear)
    {
        orderId = isBid ? _bidOrders._head(price) : _askOrders._head(price);
        ExchangeOrderbook.Order memory order = isBid ? _bidOrders._getOrder(orderId) : _askOrders._getOrder(orderId);
        required = convert(price, order.depositAmount, !isBid);
        if (required <= remaining) {
            isBid ? _bidOrders._fpop(price) : _askOrders._fpop(price);
            if (isEmpty(isBid, price)) {
                isBid
                    ? priceLists.bidHead = priceLists._next(isBid, price)
                    : priceLists.askHead = priceLists._next(isBid, price);
            }
            return (orderId, required, true); // clear orer as required <= remaining
        }
        return (orderId, required, false); // not clear order as required > remaining
    }

    function _sendFunds(address token, address to, uint256 amount) internal returns (bool) {
        address weth = IWETHMinimal(pair.engine).WETH();
        if (token == weth) {
            IWETHMinimal(token).withdraw(amount);
            return payable(to).send(amount);
        } else {
            TransferHelper.safeTransfer(token, to, amount);
            return true;
        }
    }

    // get absolute difference between two numbers and return the difference and if a is greater than b
    function _absdiff(uint8 a, uint8 b) internal pure returns (uint8, bool) {
        return (a > b ? a - b : b - a, a > b);
    }

    // get required amount for executing the order
    function getRequired(bool isBid, uint256 price, uint32 orderId) external view returns (uint256 required) {
        ExchangeOrderbook.Order memory order = isBid ? _bidOrders._getOrder(orderId) : _askOrders._getOrder(orderId);
        if (order.depositAmount == 0) return 0;

        /**
         * if ask, require base amount is quoteAmount / price,
         * converting the number converting decimal from quote to base,
         * otherwise quote amount is baseAmount * price , converting decimal from base to quote
         */
        return convert(price, order.depositAmount, isBid);
    }

    //////////////////////////// Price Linked List Methods ////////////////////////////

    // last market price
    function lmp() external view returns (uint256) {
        return priceLists.lmp;
    }

    function heads() external view returns (uint256, uint256) {
        return priceLists._heads();
    }

    function askHead() external view returns (uint256) {
        return priceLists._askHead();
    }

    function bidHead() external view returns (uint256) {
        return priceLists._bidHead();
    }

    function orderHead(bool isBid, uint256 price) external view returns (uint32) {
        return isBid ? _bidOrders._head(price) : _askOrders._head(price);
    }

    function mktPrice() external view returns (uint256) {
        return priceLists._mktPrice();
    }

    function getPrices(bool isBid, uint32 n) external view returns (uint256[] memory) {
        return priceLists._getPrices(isBid, n);
    }

    function nextPrice(bool isBid, uint256 price) external view returns (uint256 next) {
        return priceLists._next(isBid, price);
    }

    function nextOrder(bool isBid, uint256 price, uint32 orderId) public view returns (uint32 next) {
        return isBid ? _bidOrders._next(price, orderId) : _askOrders._next(price, orderId);
    }

    function sfpop(bool isBid, uint256 price, uint32 orderId, bool isHead)
        external
        view
        returns (uint32 id, uint256 required, bool clear)
    {
        id = isHead ? orderId : nextOrder(isBid, price, orderId);
        ExchangeOrderbook.Order memory order = isBid ? _bidOrders._getOrder(id) : _askOrders._getOrder(id);
        required = convert(price, order.depositAmount, !isBid);
        return (id, required, id == 0);
    }

    function getPricesPaginated(bool isBid, uint32 start, uint32 end) external view returns (uint256[] memory) {
        return priceLists._getPricesPaginated(isBid, start, end);
    }

    function getOrderIds(bool isBid, uint256 price, uint32 n) external view returns (uint32[] memory) {
        return isBid ? _bidOrders._getOrderIds(price, n) : _askOrders._getOrderIds(price, n);
    }

    function getOrders(bool isBid, uint256 price, uint32 n) external view returns (ExchangeOrderbook.Order[] memory) {
        return isBid ? _bidOrders._getOrders(price, n) : _askOrders._getOrders(price, n);
    }

    function getOrdersPaginated(bool isBid, uint256 price, uint32 start, uint32 end)
        external
        view
        returns (ExchangeOrderbook.Order[] memory)
    {
        return isBid
            ? _bidOrders._getOrdersPaginated(price, start, end)
            : _askOrders._getOrdersPaginated(price, start, end);
    }

    function getOrder(bool isBid, uint32 orderId) external view returns (ExchangeOrderbook.Order memory) {
        return isBid ? _bidOrders._getOrder(orderId) : _askOrders._getOrder(orderId);
    }

    function getBaseQuote() external view returns (address base, address quote) {
        return (pair.base, pair.quote);
    }

    /**
     * @dev get asset value in quote asset if isBid is true, otherwise get asset value in base asset
     * @param amount amount of asset in base asset if isBid is true, otherwise in quote asset
     * @param isBid if true, get asset value in quote asset, otherwise get asset value in base asset
     * @return converted asset value in quote asset if isBid is true, otherwise asset value in base asset
     */
    function assetValue(uint256 amount, bool isBid) external view returns (uint256 converted) {
        return convert(priceLists._mktPrice(), amount, isBid);
    }

    function isEmpty(bool isBid, uint256 price) public view returns (bool) {
        return isBid ? _bidOrders._isEmpty(price) : _askOrders._isEmpty(price);
    }

    function convertMarket(uint256 amount, bool isBid) external view returns (uint256 converted) {
        return convert(priceLists.lmp, amount, isBid);
    }

    function convert(uint256 price, uint256 amount, bool isBid) public view returns (uint256 converted) {
        if (isBid) {
            // convert base to quote
            return baseBquote ? ((amount * price) / 1e8) / decDiff : ((amount * price) / 1e8) * decDiff;
        } else {
            // convert quote to base
            return baseBquote ? ((amount * 1e8) / price) * decDiff : ((amount * 1e8) / price) / decDiff;
        }
    }

    receive() external payable {
        assert(msg.sender == IWETHMinimal(pair.engine).WETH());
    }
}
