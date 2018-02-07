
pragma solidity 0.4.18;

/*
  The MIT License (MIT)

  Copyright (c) 2018 Murray Software, LLC.

  Permission is hereby granted, free of charge, to any person obtaining
  a copy of this software and associated documentation files (the
  "Software"), to deal in the Software without restriction, including
  without limitation the rights to use, copy, modify, merge, publish,
  distribute, sublicense, and/or sell copies of the Software, and to
  permit persons to whom the Software is furnished to do so, subject to
  the following conditions:

  The above copyright notice and this permission notice shall be included
  in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "zeppelin-solidity/contracts/ownership/Ownable.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";

// solhint-disable avoid-low-level-calls
// solhint-disable avoid-call-value

contract DividendToken is ERC20, Ownable {
  using SafeMath for uint;

  uint[] internal totalSupplyHistory;
  mapping(address => uint[]) internal balanceHistories;
  mapping(address => mapping(address => uint)) internal allowed;

  struct Dividend {
    ERC20 token;
    uint amount;
  }

  Dividend[] internal dividends;

  event Withdrawal(address indexed holder, ERC20 indexed token, uint amount);
  event DividendIssued(ERC20 indexed token, uint amount);

  /*
   * ERC20
   */
  function totalSupply() public view returns (uint) {
    return lastValue(totalSupplyHistory);
  }

  function transfer(address _to, uint256 _value) public returns (bool) {
    require(_to != address(0));

    decrement(balanceHistories[msg.sender], _value);
    increment(balanceHistories[_to], _value);
    Transfer(msg.sender, _to, _value);
    return true;
  }

  function balanceOf(address _owner) public view returns (uint256 balance) {
    return lastValue(balanceHistories[_owner]);
  }

  function transferFrom(address _from, address _to, uint256 _value) public returns (bool) {
    require(_to != address(0));
    require(_value <= allowed[_from][msg.sender]);

    decrement(balanceHistories[_from], _value);
    increment(balanceHistories[_to], _value);
    allowed[_from][msg.sender] = allowed[_from][msg.sender].sub(_value);
    Transfer(_from, _to, _value);
    return true;
  }

  function approve(address _spender, uint256 _value) public returns (bool) {
    allowed[msg.sender][_spender] = _value;
    Approval(msg.sender, _spender, _value);
    return true;
  }

  function approveAndCall(address _spender, uint256 _value, bytes _data) public payable returns (bool success) {
    require(_spender != address(this));
    approve(_spender, _value);
    require(_spender.call.value(msg.value)(_data));
    return true;
  }

  function allowance(address _owner, address _spender) public view returns (uint256) {
    return allowed[_owner][_spender];
  }

  function increaseApproval(address _spender, uint _addedValue) public returns (bool) {
    allowed[msg.sender][_spender] = allowed[msg.sender][_spender].add(_addedValue);
    Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
    return true;
  }

  function decreaseApproval(address _spender, uint _subtractedValue) public returns (bool) {
    uint oldValue = allowed[msg.sender][_spender];
    if (_subtractedValue > oldValue) {
      allowed[msg.sender][_spender] = 0;
    } else {
      allowed[msg.sender][_spender] = oldValue.sub(_subtractedValue);
    }
    Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
    return true;
  }

  /*
   * Dividend support
   */
  function dividend(ERC20 token, uint amount) public onlyOwner {
    // since we wont give this out, don't transfer it in and decrement the dividend amount
    amount -= amount % totalSupply();
    require(token.transferFrom(msg.sender, address(this), amount));
    dividends.push(Dividend(token, amount));
    DividendIssued(token, amount);
  }

  function withdraw() public {
    uint[] storage balanceHistory = balanceHistories[msg.sender];
    if (balanceHistory.length > 0) {
      uint start = index(balanceHistory[0]);
      //NOTE: you could do a binary search on the totalSupply indices to find the starting index
      uint totalSupplyIndex = 0;
      uint totalSupplyValue = value(totalSupplyHistory[0]);
      uint balanceIndex = 0;
      uint balanceValue = value(balanceHistory[0]);
      for (uint i = start; i < dividends.length; i++) {
        while (totalSupplyIndex < totalSupplyHistory.length - 1 && index(totalSupplyHistory[totalSupplyIndex+1]) <= i) {
          totalSupplyIndex++;
          totalSupplyValue = value(totalSupplyHistory[totalSupplyIndex]);
        }
        while (balanceIndex < balanceHistory.length - 1 && index(balanceHistory[balanceIndex+1]) <= i) {
          balanceIndex++;
          balanceValue = value(balanceHistory[balanceIndex]);
        }
        Dividend storage current = dividends[i];
        uint share = current.amount * balanceValue / totalSupplyValue;
        ERC20 token = current.token;
        require(token.transfer(msg.sender, share));
        Withdrawal(msg.sender, token, share);
      }
      balanceHistory[1] = entry(dividends.length, lastValue(balanceHistory));
      balanceHistory.length = 1; // TODO: confirm that this zeros the rest of the balance history...
    }
  }

  /*
   * Utility functions for packed representations
   */
  uint internal constant SHIFT_FACTOR = 2**(256 - 64); // 64 bits of index value

  function index(uint packed) internal pure returns (uint) {
    return packed / SHIFT_FACTOR;
  }

  function value(uint packed) internal pure returns (uint) {
    return packed & (SHIFT_FACTOR - 1);
  }

  function lastValue(uint[] storage packedlist) internal view returns (uint) {
    if (packedlist.length == 0) {
      return 0;
    } else {
      return value(packedlist[packedlist.length-1]);
    }
  }

  function lastIndex(uint[] storage packedlist) internal view returns (uint) {
    if (packedlist.length == 0) {
      return 0;
    } else {
      return index(packedlist[packedlist.length-1]);
    }
  }

  function entry(uint idx, uint val) internal pure returns (uint) {
    return (idx * SHIFT_FACTOR) | (val & (SHIFT_FACTOR - 1));
  }

  function increment(uint[] storage packedList, uint incr) internal {
    if (packedList.length == 0 || index(packedList[packedList.length-1]) < dividends.length) {
      packedList.push(entry(dividends.length, incr));
    } else {
      packedList[packedList.length-1] += incr;
    }
  }

  function decrement(uint[] storage packedList, uint decr) internal {
    require(packedList.length > 0);
    uint packed = packedList[packedList.length-1];
    uint val = value(packed);
    require(val >= decr);
    if (index(packed) < dividends.length) {
      packedList.push(entry(dividends.length, val - decr));
    } else {
      packedList[packedList.length-1] = packed - decr;
    }
  }
}
