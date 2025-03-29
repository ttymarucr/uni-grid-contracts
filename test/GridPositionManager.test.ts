import { expect } from "chai";
import { ethers } from "hardhat";

describe("GridPositionManager", function () {
  // Base mainnet addresses
  const poolAddress = "0xd0b53D9277642d899DF5C87A3966A349A798F224";
  const positionManagerAddress = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1";
  const WETHAddress = "0x4200000000000000000000000000000000000006";
  const USDCAddress = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
  const slippage = 500; // 0.5% slippage

  let amount0 = ethers.utils.parseEther("0.0001");
  let amount1 = ethers.utils.parseUnits("100", 6);

  let gridPositionManager: any;
  let owner: any;
  let addr1: any;
  let addr2: any;

  before(async function () {
    const ownerAddress = "0x737284cFc66fd5989F2AC866989d70Ae134227cB";
    // Start impersonating the address
    await ethers.provider.send("hardhat_impersonateAccount", [ownerAddress]);
    // Get a signer for the impersonated address
    owner = await ethers.getSigner(ownerAddress);
    
    const [funder, address1, address2] = await ethers.getSigners();
    addr1 = address1;
    addr2 = address2;
    // Send ETH to the owner address
    const tx = await funder.sendTransaction({
        to: ownerAddress,
        value: ethers.utils.parseEther("10"), // Amount to send (10 ETH in this case)
    });

    await tx.wait();
    const wethContract = await ethers.getContractAt("IERC20", WETHAddress);
    const usdcContract = await ethers.getContractAt("IERC20", USDCAddress);

    const wethBalance = await wethContract.balanceOf(owner.address);
    const usdcBalance = await usdcContract.balanceOf(owner.address);

    console.log("Owner WETH Balance:", wethBalance.toString());
    console.log("Owner USDC Balance:", usdcBalance.toString());
    const wethBalancePercentage = wethBalance.div(100); // 1% of WETH balance
    const usdcBalancePercentage = usdcBalance.div(100); // 1% of USDC balance

    amount0 = wethBalancePercentage;
    amount1 = usdcBalancePercentage;

    console.log("Amount0 (1% WETH):", amount0.toString());
    console.log("Amount1 (1% USDC):", amount1.toString());
  });

  beforeEach(async function () {
    const iUniswapV3Pool = await ethers.getContractAt("IUniswapV3Pool", poolAddress);

    const iNonfungiblePositionManager = await ethers.getContractAt("INonfungiblePositionManager", positionManagerAddress);

    const GridPositionManager = await ethers.getContractFactory("GridPositionManager");
    gridPositionManager = await GridPositionManager.connect(owner).deploy(
      iUniswapV3Pool.address,
      iNonfungiblePositionManager.address,
      10,
      1
    );
    await gridPositionManager.deployed();
    const wethContract = await ethers.getContractAt("IERC20", WETHAddress);
    const usdcContract = await ethers.getContractAt("IERC20", USDCAddress);

    // Approve GridPositionManager to spend WETH and USDC
    await wethContract.connect(owner).approve(gridPositionManager.address, amount0);
    await usdcContract.connect(owner).approve(gridPositionManager.address, amount1);
  });

  it("Should initialize with correct parameters", async function () {
    const gridQuantity = await gridPositionManager.getGridQuantity();
    const gridStep = await gridPositionManager.getGridStep();
    expect(gridQuantity).to.equal(10);
    expect(gridStep).to.equal(1);
  });

  it("Should allow the owner to update grid step", async function () {
    await gridPositionManager.connect(owner).updateGridStep(5);
    const gridStep = await gridPositionManager.getGridStep();
    expect(gridStep).to.equal(5);
  });

  it("Should revert if non-owner tries to update grid step", async function () {
    await expect(gridPositionManager.connect(addr1).updateGridStep(5)).to.be.rejectedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("Should allow deposits and emit Deposit event", async function () {
    await expect(gridPositionManager.connect(owner).deposit(amount0, amount1, slippage))
      .to.emit(gridPositionManager, "Deposit")
      .withArgs(owner.address, amount0, amount1);
  });

  it("Should allow the owner to withdraw and emit Withdraw event", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage);

    await expect(gridPositionManager.withdraw())
      .to.emit(gridPositionManager, "Withdraw");
  });

  it("Should revert if non-owner tries to withdraw", async function () {
    await expect(gridPositionManager.connect(addr1).withdraw()).to.be.rejectedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("Should allow compounding fees", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage);
    await expect(gridPositionManager.connect(owner).compound(slippage)).to.emit(gridPositionManager, "Compound");
  });

  it("Should allow sweeping positions", async function () {
    await gridPositionManager.connect(owner).deposit(amount0, amount1, slippage);
    await expect(gridPositionManager.sweep(slippage)).to.not.be.rejected;
  });

  it("Should revert Ether transfers", async function () {
    await expect(
      owner.sendTransaction({
        to: gridPositionManager.address,
        value: ethers.utils.parseEther("1"),
      })
    ).to.be.rejectedWith("Ether transfers not allowed");
  });
});
