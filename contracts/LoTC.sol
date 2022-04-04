//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./Medal.sol";

/**
    Lord Of The Chain 
    As an owner I want to inherit the admin permissions of the smart contract once it is deployed
    As an admin I want to be the only one able to populate the contract with customizable bosses
    As an user I want to be able to randomly generated one character per address
    As an user I want to be able to attack the current boss with my character
    As an user I should be able to heal other characters with my character
    As an user I want to be able to claim rewards of defeated bosses
 
    Everytime a player attack the boss, the boss will counterattack the player. Both will loose life points
    A dead character can no longer do anything but can be healed
    Only characters who attacked the boss can receive the reward in xp
    A new boss can't be populated if the current one isn't defeated
    A player can't heal himself
    Only players who already earn experiences can cast the heal spell

    
    Earning experiences isn't enough. Implement a level system based on the experience gained. 
    Casting the heal spell will require a level 2 character and casting a fire ball spell will require a level 3 character. 
    The fire ball spell can only be casted every 24 hours. Each time a character dies, he must loose experience points

    We decided to use cryptopunks as bosses. 
    Please, interface the cryptopunk contract to allow admin to generate cryptopunks bosses. 
    Develop the smart contract in such a way that anyone can create a frontend connected to the contract and use the cryptopunk metadata 
    to display the boss.
    
    Players should be able to brag their fights participations. 
    Allow players to mint a non-fungible token when they claim the reward of a defeated boss. 
    Inspired by the LOOT project, the NFT should be fully on-chain and display some information about the defeated boss. 
    Don't be focus on the NFT itself, it doesn't need to be impressive or include any art

 */

contract LordOfChain is AccessControl, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMath for uint16;

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OWNER = keccak256("OWNER");
    bytes32 private constant PLAYER = keccak256("PLAYER");
    uint8 public constant INITIAL_STAT_POINTS = 30;

    struct Character {
        uint256 hp;
        uint256 exhausted;
        uint256 magic;
        uint128 xp;
        uint8 level;
        uint8 str;
        uint8 end;
        uint8 inte;
    }

    struct Boss {
        uint256 hp;
        uint256 bounty;
        uint8 level;
        uint8 str;
        uint8 end;
        uint8 inte;
        address lastHit;
        mapping(address => uint256) damage;
    }

    uint256[256] public expirienceTable;
    mapping(uint256 => Boss) public invaders;
    mapping(address => Character) public players;
    mapping(address => uint256) public gold;

    Medal public medal;
    address public medalContract;

    constructor() {
        _setupRole(OWNER, msg.sender);
        _setupRole(ADMIN, msg.sender);
        _setRoleAdmin(OWNER, OWNER);
        _setRoleAdmin(ADMIN, OWNER);
        _setRoleAdmin(PLAYER, OWNER);
    }

    modifier aliveBoss(uint256 _bossId) {
        require(invaders[_bossId].hp > 0, "Boss already defeated!");
        _;
    }

    modifier characterReady() {
        require(players[msg.sender].hp > 0, "You're dead, wait for reborn!");
        require(
            players[msg.sender].exhausted < block.timestamp,
            "You need to rest before attack!"
        );
        _;
    }

    event CharacterResurrection();
    event NewBossInvading();
    event BossDefeated();
    event LevelUp();
    event PlayerKilled();
    event MedalReceived();

    function createCharacter() public payable {
        require(msg.value > 0.1 ether, "You need 0.1eth to create a char");
        require(players[msg.sender].level == 0, "You have already been born!");
        players[msg.sender].level = 1;
        (players[msg.sender].str, players[msg.sender].end) = _randomizeStats(
            INITIAL_STAT_POINTS
        );
        players[msg.sender].inte =
            INITIAL_STAT_POINTS -
            (players[msg.sender].str + players[msg.sender].end);
        _grantRole(PLAYER, msg.sender);
    }

    function _randomizeStats(uint16 _statPoints)
        internal
        view
        returns (uint8 _str, uint8 _end)
    {
        uint8 minValue = uint8(
            _statPoints / 3 - _statPoints - (_statPoints / 10)
        );
        uint8 maxValue = uint8(
            _statPoints / 3 - _statPoints + (_statPoints / 10)
        );
        _str =
            (uint8(
                uint256(
                    keccak256(abi.encodePacked(msg.sender, block.timestamp))
                )
            ) % (maxValue - minValue + 1)) +
            minValue;
        _end =
            (uint8(
                uint256(keccak256(abi.encodePacked(msg.sender, block.coinbase)))
            ) % (maxValue - minValue + 1)) +
            minValue;
    }

    function _damageCalculation(uint256 _bossId)
        internal
        view
        returns (uint256 playerDamage, uint256 bossDamage)
    {
        playerDamage =
            players[msg.sender].str -
            (invaders[_bossId].end / 2) +
            players[msg.sender].level;
        bossDamage =
            (invaders[_bossId].str -
                (players[msg.sender].end / 2) +
                players[msg.sender].level) *
            2;
    }

    function attackBoss(uint256 _bossId)
        public
        payable
        aliveBoss(_bossId)
        characterReady
        onlyRole(PLAYER)
        nonReentrant
    {
        (uint256 playerDamage, uint256 bossDamage) = _damageCalculation(_bossId);
        (, players[msg.sender].hp) = players[msg.sender].hp.trySub(bossDamage);
        (, invaders[_bossId].hp) = invaders[_bossId].hp.trySub(playerDamage);
        invaders[_bossId].damage[msg.sender] =
            invaders[_bossId].damage[msg.sender] +
            playerDamage;
        if (players[msg.sender].hp > 0)
            players[msg.sender].exhausted = block.timestamp + 14400;
        if (players[msg.sender].hp == 0) {
            players[msg.sender].exhausted = block.timestamp + 86400;
            emit PlayerKilled();
        }
        if (invaders[_bossId].hp == 0) {
            invaders[_bossId].lastHit = msg.sender;
            emit BossDefeated();
        }
    }

    function fireBreath(uint256 _bossId)
        public
        nonReentrant
        aliveBoss(_bossId)
        onlyRole(PLAYER)
    {
        require(
            players[msg.sender].magic < block.timestamp,
            "You dont have magic points left"
        );
        require(
            players[msg.sender].inte >= 30,
            "Your intelligence must be +30"
        );
        uint256 playerDamage;
        playerDamage = players[msg.sender].inte + players[msg.sender].str;
        (, invaders[_bossId].hp) = invaders[_bossId].hp.trySub(playerDamage);
        invaders[_bossId].damage[msg.sender] =
            invaders[_bossId].damage[msg.sender] +
            playerDamage;
        if (invaders[_bossId].hp == 0) {
            invaders[_bossId].lastHit = msg.sender;
            emit BossDefeated();
        }
    }

    function resurrectPlayer(address _targetAddress) public onlyRole(PLAYER) {
        require(
            players[_targetAddress].hp == 0,
            "This character is still alive!"
        );
        if (_targetAddress != msg.sender) {
            require(
                players[msg.sender].magic < block.timestamp,
                "You have already revive today"
            );
            require(
                players[msg.sender].inte >= 15,
                "Your intelligence must be +15"
            );
            players[_targetAddress].hp = players[_targetAddress].level * 10;
        }
        if (_targetAddress == msg.sender) {
            require(
                players[msg.sender].exhausted < block.timestamp,
                "You need to wait one day!"
            );
            players[_targetAddress].hp = players[_targetAddress].level * 10;
        }
    }

    function newInvadingBoss(uint256 _bossId, uint8 _level)
        public
        onlyRole(ADMIN)
    {
        require(_bossId > 0, "Boss Id must be different from 0");
        require(invaders[_bossId].level == 0, "This boss Id already exist!");
        uint16 bossStats = uint16(INITIAL_STAT_POINTS) + uint16(_level);
        invaders[_bossId].hp = _level * 100;
        invaders[_bossId].bounty = invaders[_bossId].hp * 10;
        (invaders[_bossId].str, invaders[_bossId].end) = _randomizeStats(
            bossStats
        );
        emit NewBossInvading();
    }

    function claimRewards(uint256 _bossId) private {
        require(invaders[_bossId].hp == 0, "This boss is still alive!");
        Character storage char = players[msg.sender];
        if (char.level < 255) {
            uint256 newXp = uint256(char.xp).add(
                invaders[_bossId].damage[msg.sender]
            );
            uint256 requiredXpToLevel = expirienceTable[char.level];
            while (newXp >= requiredXpToLevel) {
                newXp = newXp - requiredXpToLevel;
                char.level++;
                emit LevelUp();
                if (char.level < 255)
                    requiredXpToLevel = expirienceTable[char.level];
                else newXp = 0;
            }
        }
        gold[msg.sender] =
            gold[msg.sender] +
            (invaders[_bossId].bounty *
                (
                    ((invaders[_bossId].level * 100) /
                        invaders[_bossId].damage[msg.sender] /
                        100)
                ));
        if (invaders[_bossId].lastHit == msg.sender){
            medal.awardItem(msg.sender);
            emit MedalReceived();
            }
    }

    function deleteBoss(uint256 _bossIndex) public onlyRole(ADMIN) {
        require(invaders[_bossIndex].hp == 0, "This boss is still invading!");
        invaders[_bossIndex].level = 0;
    }

    function updateExpTable(uint256[255] memory _experienceTable)
        public
        onlyRole(OWNER)
    {
        expirienceTable = _experienceTable;
    }

    function getExpTable() public view returns (uint256[256] memory) {
        return expirienceTable;
    }

    function setNewAdmin(address _newAdmin) public onlyRole(OWNER) {
        grantRole(ADMIN, _newAdmin);
    }

    function deleteAdmin(address _deleteAdmin) public onlyRole(OWNER) {
        revokeRole(ADMIN, _deleteAdmin);
    }
}
