// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {FilesFinalValidator} from "../../src/profiles/FilesFinalValidator.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {FamilyId, Purpose, ScopeKey} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {DigestSpec, FamilyEntry, Unit, WorkModel} from "../../src/interfaces/Index.sol";
import {E_DEPLOYER, E_PIN} from "../../src/interfaces/Errors.sol";

/// A final hook that answers every validator call but has no topic getters (any other profile's unit).
contract NoTopicGettersHook {
    function validate(uint64, bytes calldata, bytes calldata) external pure returns (bytes4) {
        return 0;
    }
}

/// A reads contract that copies a real one's manifest but claims topic Type ids the real one does not hold: the
/// generation must not believe it (its own constructor re-checks the units it copies).
contract LyingReads {
    IndexReads internal immutable REAL;
    bytes32 internal immutable TOPIC;
    bytes32 internal immutable WORD;

    constructor(IndexReads real, bytes32 topic, bytes32 word) {
        REAL = real;
        TOPIC = topic;
        WORD = word;
    }

    function manifest()
        external
        view
        returns (
            bytes32,
            FamilyEntry[] memory,
            Unit[] memory,
            DigestSpec[] memory,
            WorkModel memory,
            bytes32,
            bytes32
        )
    {
        return REAL.manifest();
    }

    function ledger() external view returns (address) {
        return REAL.ledger();
    }

    function postingStore() external view returns (address) {
        return REAL.postingStore();
    }

    function bitmapStore() external view returns (address) {
        return REAL.bitmapStore();
    }

    function topicTypes() external view returns (bytes32, bytes32) {
        return (TOPIC, WORD);
    }
}

/// @notice The topic lists have no trust setting (design §10.2; docs/TAG-DESIGN.md §11.7): the index walks a
///         tagged topic's ancestors without checking that the topic was registered first, so it keeps the topic
///         lists (`scope-below`, `place-below`) only when its fixed unit list holds a final hook built for the same
///         two topic Types, which refuses any other first tag (`FilesFinalValidator` code 9). Every other
///         combination cannot be deployed: the reads contract's constructor, the generation's constructor and the
///         `IndexDeployer` all refuse it. Zero topic Type ids deploy, keep no topic lists and report them UNKNOWN.
contract TopicListsConfigTest is Test {
    bytes32 internal constant TOPIC = keccak256("test/topic/1");
    bytes32 internal constant WORD = keccak256("test/topic-word/1");

    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    PostingStore internal posting;
    BitmapStore internal bitmap;
    FilesFinalValidator internal built; // built for (TOPIC, WORD)
    FilesFinalValidator internal other; // built for another topic Type

    function setUp() public {
        registry = new MockRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("salt"));
        posting = new PostingStore(k.proxy, address(0), IndexDeploy.postingFamilies());
        bitmap = new BitmapStore(k.proxy, address(0), IndexDeploy.bitmapFamilies());
        built = new FilesFinalValidator(
            keccak256("name"), keccak256("dir"), keccak256("root"), keccak256("child"), TOPIC, WORD
        );
        other = new FilesFinalValidator(
            keccak256("name"),
            keccak256("dir"),
            keccak256("root"),
            keccak256("child"),
            keccak256("another topic Type"),
            WORD
        );
    }

    function _unit(address hook) internal view returns (Unit memory u) {
        u.finalHook = hook;
        u.finalCodehash = hook.codehash;
        u.familyIds = new bytes32[](0);
        u.purposeFilter = Purpose.FOLDER;
        u.hotAbiId = KernelDeploy.HOT_ABI_ID;
    }

    function _units(address hook) internal view returns (Unit[] memory u) {
        u = new Unit[](1);
        u[0] = _unit(hook);
    }

    function _reads(Unit[] memory units, bytes32 topic, bytes32 word)
        internal
        returns (IndexReads)
    {
        return new IndexReads(
            k.proxy,
            KernelDeploy.HOT_ABI_ID,
            address(posting),
            address(bitmap),
            units,
            new DigestSpec[](0),
            IndexDoubleDefaults.workModel(),
            topic,
            word,
            ""
        );
    }

    function _refused() internal {
        vm.expectRevert(abi.encodeWithSelector(E_PIN.selector, address(0), uint8(11)));
    }

    // ---- the reads contract refuses every misconfiguration --------------------------------------------------------

    function test_topic_ids_without_any_unit_cannot_be_deployed() public {
        _refused();
        _reads(new Unit[](0), TOPIC, WORD);
    }

    function test_topic_ids_with_a_unit_built_for_other_topic_types_cannot_be_deployed() public {
        _refused();
        _reads(_units(address(other)), TOPIC, WORD);
    }

    function test_swapped_topic_ids_cannot_be_deployed() public {
        _refused();
        _reads(_units(address(built)), WORD, TOPIC);
    }

    function test_one_zero_topic_id_cannot_be_deployed() public {
        _refused();
        _reads(_units(address(built)), TOPIC, 0);
        _refused();
        _reads(_units(address(built)), 0, WORD);
    }

    function test_a_final_hook_without_topic_getters_does_not_count() public {
        Unit[] memory none = _units(address(new NoTopicGettersHook()));
        _refused();
        _reads(none, TOPIC, WORD);
        // nor does an account without code, nor the validator as a fold hook only
        _refused();
        _reads(_units(address(0xBEEF)), TOPIC, WORD);
        Unit[] memory u = new Unit[](1);
        u[0].foldHook = address(built);
        _refused();
        _reads(u, TOPIC, WORD);
    }

    function test_the_matching_unit_deploys_among_others() public {
        Unit[] memory u = new Unit[](3);
        u[0] = _unit(address(other));
        u[1] = _unit(address(new NoTopicGettersHook()));
        u[2] = _unit(address(built));
        IndexReads reads = _reads(u, TOPIC, WORD);
        (bytes32 t, bytes32 w) = reads.topicTypes();
        assertEq(t, TOPIC);
        assertEq(w, WORD);
        RealmIndex index = new RealmIndex(k.proxy, address(0), address(reads));
        (t, w) = IndexReads(address(index)).topicTypes(); // forwarded to the reads contract
        assertEq(t, TOPIC);
        assertEq(w, WORD);
    }

    // ---- the generation re-checks what it copies -------------------------------------------------------------------

    function test_the_generation_refuses_a_reads_contract_claiming_topic_ids_its_units_do_not_back()
        public
    {
        IndexReads honest = _reads(new Unit[](0), 0, 0);
        LyingReads liar = new LyingReads(honest, TOPIC, WORD);
        _refused();
        new RealmIndex(k.proxy, address(0), address(liar));
        // one id zero is refused there too
        liar = new LyingReads(honest, TOPIC, 0);
        _refused();
        new RealmIndex(k.proxy, address(0), address(liar));
    }

    function test_the_index_deployer_cannot_build_a_misconfigured_generation() public {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.readsInitcode = type(IndexReads).creationCode;
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = _units(address(other));
        plan.specs = new DigestSpec[](0);
        plan.work = IndexDoubleDefaults.workModel();
        plan.topicTypeId = TOPIC;
        plan.topicWordTypeId = WORD;
        plan.liveManifest = ManifestCopy.ofLive(k.proxy);
        IndexDeployer d = new IndexDeployer(k.proxy, keccak256(abi.encode(plan)));
        // the reads contract's creation reverts, which the deployer reports as a failed creation
        vm.expectRevert(abi.encodeWithSelector(E_DEPLOYER.selector, uint8(2)));
        d.run(plan);
    }

    // ---- zero topic ids: no topic lists, reported as such ----------------------------------------------------------

    function test_zero_topic_ids_keep_no_topic_lists() public {
        // with or without a validator in the unit list
        IndexReads reads = _reads(_units(address(built)), 0, 0);
        RealmIndex index = new RealmIndex(k.proxy, address(0), address(reads));
        (, FamilyEntry[] memory families,,,,,) = reads.manifest();
        assertEq(families.length, 19);
        for (uint256 i; i < families.length; ++i) {
            bytes32 id = families[i].familyId;
            bool topicList =
                id == Keys.familyId("scope-below") || id == Keys.familyId("place-below");
            bool reserved = id == Keys.familyId("roster");
            assertEq(families[i].mandatory, !topicList && !reserved, "maintained");
        }
        (Coverage c,,,) = IndexReads(address(index))
            .coverage(FamilyId.wrap(Keys.familyId("scope-below")), ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(Coverage.UNKNOWN), "scope-below not maintained");
        (c,,,) = IndexReads(address(index))
            .coverage(FamilyId.wrap(Keys.familyId("place-below")), ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(Coverage.UNKNOWN), "place-below not maintained");
        // a configured generation maintains them, so the two manifests (and their hashes) differ
        IndexReads withTopics = _reads(_units(address(built)), TOPIC, WORD);
        (, FamilyEntry[] memory f2,,,,,) = withTopics.manifest();
        assertTrue(keccak256(abi.encode(families)) != keccak256(abi.encode(f2)));
    }
}
