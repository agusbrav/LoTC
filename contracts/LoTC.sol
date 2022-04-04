//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./Medal.sol";

/**
 * @title Lords Of The Chain RPG.
 * @author Agusbrav
 * TBD :  - GUILDS creation from LORD role Champions can join guilds and participate in SIEGES
 *        - SIEGE Fight between guilds for a CASTLE. Earn ETH from victory and defend your castle to become the ultimate Lord.
 *        - WEAPON / ARMOR system. Change your medals with equipments that enhance your skills for SIEGES.
 */

contract LordOfChain is AccessControl, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMath for uint128;

    /**
     * @dev Defining constant roles for AccessControl use.
     * ADMIN should be able to load new bosses in to the land.
     */
    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OWNER = keccak256("OWNER");

    /**
     * @dev Defining constant roles for AccessControl use.
     * CHAMPION role enables you once the character creation in order to 
     * interact with bosses / other players.
     */
    bytes32 private constant CHAMPION = keccak256("CHAMPION");
    bytes32 private constant LORD = keccak256("LORD");
    uint8 public constant INITIAL_STAT_POINTS = 30;

    ///@dev Data used and assigned to players character
    struct Character {
        uint256 hp;
        uint256 exhausted;
        uint256 magic;
        uint128 xp;
        uint8 level;
        uint8 str;
        uint8 end;
        uint8 inte;
        uint8 karma;
    }

    ///@dev Boss stats and info, damage accumulation by player.
    struct Boss {
        uint256 hp;
        uint256 bounty;
        uint8 level;
        uint8 str;
        uint8 end;
        uint8 inte;
        address lastHit;
        uint256 deadTimmer;
        mapping(address => uint256) damage;
    }

    ///@notice This table needs to bee loaded manually by the owner in order to apply the current level requirements
    uint256[256] public expirienceTable;

    ///Mapings of bosses(invaders), characters(players) and gold of each address;
    mapping(uint256 => Boss) public invaders;
    mapping(address => Character) public players;
    mapping(address => uint256) public gold;

    ///NFT Contract of ERC721 Token 
    Medal public medal;
    address public medalContract;

    /**
     * @dev Assign initial roles for the contract
     */
    constructor() {
        _setupRole(OWNER, msg.sender);
        _setupRole(ADMIN, msg.sender);
        _setRoleAdmin(OWNER, OWNER);
        _setRoleAdmin(ADMIN, OWNER);
        _setRoleAdmin(CHAMPION, OWNER);
        _setRoleAdmin(LORD, ADMIN);
    }

    ///@dev modifier to assure that the boss you are trying to interact with has Hp remaining (for attacks)
    modifier aliveBoss(uint256 _bossId) {
        require(invaders[_bossId].hp > 0, "Boss already defeated!");
        _;
    }

    ///@dev Also for attacks, check the character heal points and if it can attack after resting
    modifier characterReady() {
        require(players[msg.sender].hp > 0, "You're dead, wait for reborn!");
        require(
            players[msg.sender].exhausted < block.timestamp,
            "You need to rest before attack!"
        );
        _;
    }

    ///Can be triggered by some else by casting ressurectCharacter or by the player it self after the exhausted time has passed.
    event CharacterResurrection();

    ///Triggered when any ADMIN executes newInvadingBoss function.
    event NewBossInvading();

    ///After defeating a boss this event will trigger with the address of the champion who killed the boss and its Id.
    event BossDefeated();

    ///When claiming rewards your character may level up depending the expirience table requirements.
    event LevelUp();

    ///If you char reachs 0hp you wont be able to attack or resurrect other players. You'll need to wait the exhausted time or be revived by some other player.
    event PlayerKilled();

    ///The champion that gives the last attack will receive a ER721 Medal, recognizing the players achievement.
    event MedalReceived();

    ///Inform boss Ids, stats and current HP remaining.
    event BossReport();

    ///When a boss lvl30+ has been killed the champion who killed it will be assined a new role of LORD.
    event NewLordInLands();
    /**
     * @dev The creation of the character set your stats randomize and initialize the structure of "Character" 
     * Only one character per address is allowed.
     * @notice You need to pay the contract with 0.1 eth to create your character. 
     * Once created you can begin your journey to become a Lord.
     */
    function createCharacter() public payable {
        require(msg.value > 0.1 ether, "You need 0.1eth to create a char");
        require(players[msg.sender].level == 0, "You have already been born!");
        players[msg.sender].level = 1;
        (players[msg.sender].str, players[msg.sender].end) = _randomizeStats(
            INITIAL_STAT_POINTS - 10
        );
        players[msg.sender].inte =
            INITIAL_STAT_POINTS -
            (players[msg.sender].str + players[msg.sender].end);
        _grantRole(CHAMPION, msg.sender);
    }

    /**
     * @dev Pseudo randomize stats. Since its only used to create bosses and characters
     * there is no need to a real random number from oracle. 
     * @param _statPoints The number of points that will be randomize between a porcentage of total points.
     * @return _str The strength will calculate the damage done by the character/boss.
     * @return _end Endurance will block a percentage of the attack done by the attacker. 
     */
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

    /**
     * @dev Damage calculation formula is given from the relationship between the variables of str and end of the character and boss target.
     * The boss has an advantage of x2 damage from the char damage formula.
     * @param _bossId The target boss that the champion is attacking.
     * @return playerDamage Number of HP points that will hit the Boss.
     * @return bossDamage Number of HP points that the boss will hit to the character.
     */
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

    /**
     * @dev Primary attack function, called by the msg.sender character. 
     * @notice This function will be the first function to interact with new players
     * If the player HP points reach 0 it will take out part of the expirience accumulated by the player
     * The character wont be leveling down but the expirience target to the next level will keep the same.
     * @param _bossId The boss target that caller wants to engage with. You can check current bosses stats
     * and levels by calling invadersReport view function.
     */
    function attackBoss(uint256 _bossId)
        public
        payable
        aliveBoss(_bossId)
        characterReady
        onlyRole(CHAMPION)
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
            if (players[msg.sender].xp > 0) players[msg.sender].xp.trySub(players[msg.sender].xp/10);
            emit PlayerKilled();
        }
        _checkBoss(_bossId);
    }

    /**
     * @notice This spell will be called once you level up and upgrade your inte stat
     * The magic attacks will ignore boss endurance.
     * @param _bossId The boss target that caller wants to engage with. You can check current bosses stats
     * and levels by calling invadersReport view function.
     */
    function fireBreath(uint256 _bossId)
        public
        nonReentrant
        aliveBoss(_bossId)
        onlyRole(CHAMPION)
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
        _checkBoss(_bossId);
    }

    function _checkBoss(uint256 _bossId) internal {
         if (invaders[_bossId].hp == 0) {
            invaders[_bossId].lastHit = msg.sender;
            invaders[_bossId].deadTimmer = block.timestamp + 432000;
            emit BossDefeated();
        }
    }
    /**
     * @notice Champions car revive other champions if you have the required intelligence (15)
     * If you died in battle and your exhausted time has passed (1 day) you can revive your self.
     * If you havent died and your health is lower than your level (10% of max health) you can heal yoursel to avoid death.
     * @param _targetAddress The address of the champion you wish to heal.
     */
    function resurrectPlayer(address _targetAddress) public onlyRole(CHAMPION) {
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
            emit CharacterResurrection();
        }
        if (_targetAddress == msg.sender) {
            require(
                players[msg.sender].exhausted < block.timestamp,
                "You need to wait one day!"
            );
            require(
                players[msg.sender].hp < players[msg.sender].level,
                "You cant heal with that HP"
            );
            players[_targetAddress].hp = players[_targetAddress].level * 10;
            emit CharacterResurrection();
        }
    }

    /**
     * @dev Only ADMIN role may call new bosses, the boss Id must be different from 0 and must be empty.
     * @notice Admins will spawm bosses across the land the stats and HP will depend on the input parameters.
     * @param _bossId The boss id that will be loaded in to the mapping.
     * @param _level The level of the boss you want to create, the stats, hp and bounty of the boss are related to the level.
     */
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

    /**
     * @notice After defeating a boss you will be able to claim the corresponding rewards.
     * Such as Gold, Expirience and if the boss is +level 30 it will have a chance to drop a Medal to the last hitter.
     * The expirience claimed will come from the damage you made to the boss.
     * @param _bossId The boss target that caller will claim rewards. 
     */
    function claimRewards(uint256 _bossId) private {
        require(invaders[_bossId].hp == 0, "This boss is still alive!");
        Character storage char = players[msg.sender];
        if (char.level < 255) {
            uint256 newXp = uint256(char.xp).add(
                invaders[_bossId].damage[msg.sender]
            );
            invaders[_bossId].damage[msg.sender] = 0;
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
        if (invaders[_bossId].lastHit == msg.sender && invaders[_bossId].level>=30){
            medal.awardItem(msg.sender);
            grantRole(LORD, msg.sender);
            emit NewLordInLands();
            emit MedalReceived();
            }
    }

    /**
     * @dev Emits an event of all current alive bosses and their stats.
     * TBD
     */
    function invadersReport() public view{

    }

    /**
     * @dev Creates a New guild. Only the LORDS role can create a Guild and participate in SIEGES
     * TBD
     */
    function createGuild () public payable onlyRole (LORD){
        ///TBD
    }

    /**
     * @notice Once a boss has been defeated, the ADMINs can delete it from the mapping and use the id to a new boss
     * You will need to wait for 5 days after the boss has been defeated.
     * @param _bossIndex The boss target that ADMIN will delete. After deleting the 
     */
    function deleteBoss(uint256 _bossIndex) public onlyRole(ADMIN) {
        require(invaders[_bossIndex].hp == 0, "This boss is still invading!");
        require(invaders[_bossIndex].deadTimmer < block.timestamp,"Cant delete before 5 days");
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
