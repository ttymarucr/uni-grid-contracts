import { expect } from "chai";
import { createPublicClient, createWalletClient, http, getContract, parseEther } from "viem";
import { hardhat } from "viem/chains";
import { deployContract } from "@nomicfoundation/hardhat-toolbox-viem";

describe("GridPositionManager", function () {
  // Base mainnet addresses
  const poolAddress = "0xd0b53D9277642d899DF5C87A3966A349A798F224";
  const positionManagerAddress = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1";

  let gridPositionManager: any;
  let owner: any;
  let addr1: any;
  let addr2: any;
  let client: any;

  beforeEach(async function () {
    client = createPublicClient({ chain: hardhat, transport: http() });
    const walletClient = createWalletClient({ chain: hardhat, transport: http() });
    [owner, addr1, addr2] = await walletClient.getAddresses();

    const mockPool = await deployContract(walletClient, {
      abi: [], // Replace with MockPool ABI
      bytecode: "0x...", // Replace with MockPool bytecode
    });

    const mockPositionManager = await deployContract(walletClient, {
      abi: [], // Replace with MockPositionManager ABI
      bytecode: "0x...", // Replace with MockPositionManager bytecode
    });

    const gridPositionManagerDeployment = await deployContract(walletClient, {
      abi: [], // Replace with GridPositionManager ABI
      bytecode: "0x...", // Replace with GridPositionManager bytecode
      args: [mockPool.address, mockPositionManager.address, 10, 1],
    });

    gridPositionManager = getContract({
      address: gridPositionManagerDeployment.address,
      abi: [], // Replace with GridPositionManager ABI
      publicClient: client,
    });
  });

  it("Should initialize with correct parameters", async function () {
    const gridQuantity = await gridPositionManager.read.getGridQuantity();
    const gridStep = await gridPositionManager.read.getGridStep();
    expect(gridQuantity).to.equal(10n);
    expect(gridStep).to.equal(1n);
  });

  it("Should allow the owner to update grid step", async function () {
    await gridPositionManager.write.updateGridStep({ args: [5], account: owner });
    const gridStep = await gridPositionManager.read.getGridStep();
    expect(gridStep).to.equal(5n);
  });

  it("Should revert if non-owner tries to update grid step", async function () {
    await expect(
      gridPositionManager.write.updateGridStep({ args: [5], account: addr1 })
    ).to.be.rejectedWith("Ownable: caller is not the owner");
  });

  it("Should allow deposits and emit Deposit event", async function () {
    await expect(
      gridPositionManager.write.deposit({ args: [1000, 2000], account: owner })
    ).to.emit(gridPositionManager, "Deposit").withArgs(owner, 1000, 2000);
  });

  it("Should allow the owner to withdraw and emit Withdraw event", async function () {
    await gridPositionManager.write.deposit({ args: [1000, 2000], account: owner });
    await expect(gridPositionManager.write.withdraw({ account: owner }))
      .to.emit(gridPositionManager, "Withdraw")
      .withArgs(owner, 0, 0); // Mock balances
  });

  it("Should revert if non-owner tries to withdraw", async function () {
    await expect(gridPositionManager.write.withdraw({ account: addr1 })).to.be.rejectedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("Should allow compounding fees", async function () {
    await gridPositionManager.write.deposit({ args: [1000, 2000], account: owner });
    await expect(gridPositionManager.write.compound({ args: [100], account: owner })).to.emit(
      gridPositionManager,
      "Compound"
    );
  });

  it("Should allow sweeping positions", async function () {
    await gridPositionManager.write.deposit({ args: [1000, 2000], account: owner });
    await expect(gridPositionManager.write.sweep({ account: owner })).to.not.be.rejected;
  });

  it("Should revert Ether transfers", async function () {
    await expect(
      client.sendTransaction({
        to: gridPositionManager.address,
        value: parseEther("1"),
        account: owner,
      })
    ).to.be.rejectedWith("Ether transfers not allowed");
  });
});
