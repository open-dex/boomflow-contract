pragma solidity 0.5.16;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/roles/WhitelistAdminRole.sol";

/* Remix IDE
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/math/SafeMath.sol";
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/access/roles/WhitelistAdminRole.sol";
*/

contract TimeLock is WhitelistAdminRole
{
    using SafeMath for uint256;

    uint256 public _deferTime;

    event ScheduleWithdraw(address indexed sender, uint256 time);

    mapping (address => uint256) private _withdrawSchedule;

    constructor (uint256 releaseTime) public {
        _deferTime = releaseTime;
    }

    modifier withdrawRequested() {
        require(
            _withdrawSchedule[_msgSender()] != 0,
            "FORCE_WITHDRAW_NOT_REQUESTED"
        );
        _;
    }

    modifier pastTimeLock() {
        require(
            block.timestamp >= _withdrawSchedule[_msgSender()].add(_deferTime),
            "TIME_LOCK_INCOMPLETE"
        );
        _;
    }

    function deferTime() public view returns (uint256) {
        return _deferTime;
    }

    function getDeferTime(address account) public onlyWhitelistAdmin view returns (uint256) {
        return _withdrawSchedule[account];
    }

    function setDeferTime(uint256 time) public onlyWhitelistAdmin returns (bool) {
        _deferTime = time;
        return true;
    }

    function setScheduleTime(address account, uint256 time) internal {
        _withdrawSchedule[account] = time;

        emit ScheduleWithdraw(account, time);
    }
}