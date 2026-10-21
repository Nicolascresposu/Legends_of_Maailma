-- CreateEnum
CREATE TYPE "DeckFormat" AS ENUM ('STANDARD', 'WILD');

-- CreateEnum
CREATE TYPE "EconomyTransactionType" AS ENUM ('CRAFT', 'DISENCHANT', 'TRADE', 'PACK_OPEN', 'REWARD', 'ADMIN_GRANT');

-- CreateEnum
CREATE TYPE "TradeStatus" AS ENUM ('OPEN', 'ACCEPTED', 'CANCELLED', 'FAILED');

-- AlterTable
ALTER TABLE "decks" ADD COLUMN     "format" "DeckFormat" NOT NULL DEFAULT 'STANDARD';

-- AlterTable
ALTER TABLE "users" ADD COLUMN     "isAdmin" BOOLEAN NOT NULL DEFAULT false;

-- CreateTable
CREATE TABLE "expansion_policy_overrides" (
    "expansionId" TEXT NOT NULL,
    "released" BOOLEAN NOT NULL,
    "tradeable" BOOLEAN NOT NULL,
    "duplicateProtection" BOOLEAN NOT NULL,
    "craftable" BOOLEAN NOT NULL,
    "disenchantable" BOOLEAN NOT NULL,
    "availableInPacks" BOOLEAN NOT NULL,
    "standard" BOOLEAN NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    "updatedBy" TEXT,

    CONSTRAINT "expansion_policy_overrides_pkey" PRIMARY KEY ("expansionId")
);

-- CreateTable
CREATE TABLE "user_economy" (
    "userId" TEXT NOT NULL,
    "fragmentBalance" INTEGER NOT NULL DEFAULT 0,
    "version" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "user_economy_pkey" PRIMARY KEY ("userId")
);

-- CreateTable
CREATE TABLE "economy_transactions" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "type" "EconomyTransactionType" NOT NULL,
    "cardId" TEXT,
    "quantity" INTEGER NOT NULL DEFAULT 0,
    "fragmentDelta" INTEGER NOT NULL DEFAULT 0,
    "metadata" JSONB,
    "tradeId" TEXT,
    "requestId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "economy_transactions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "economy_requests" (
    "requestId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "operation" TEXT NOT NULL,
    "result" JSONB NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "economy_requests_pkey" PRIMARY KEY ("requestId")
);

-- CreateTable
CREATE TABLE "trades" (
    "id" TEXT NOT NULL,
    "participantAId" TEXT NOT NULL,
    "participantBId" TEXT NOT NULL,
    "status" "TradeStatus" NOT NULL DEFAULT 'OPEN',
    "revision" INTEGER NOT NULL DEFAULT 0,
    "acceptedARev" INTEGER,
    "acceptedBRev" INTEGER,
    "failureCode" TEXT,
    "failureMessage" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    "completedAt" TIMESTAMP(3),

    CONSTRAINT "trades_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "trade_items" (
    "id" TEXT NOT NULL,
    "tradeId" TEXT NOT NULL,
    "offeringUserId" TEXT NOT NULL,
    "cardId" TEXT NOT NULL,
    "quantity" INTEGER NOT NULL,

    CONSTRAINT "trade_items_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "trade_history" (
    "id" TEXT NOT NULL,
    "tradeId" TEXT NOT NULL,
    "revision" INTEGER NOT NULL,
    "fromUserId" TEXT NOT NULL,
    "toUserId" TEXT NOT NULL,
    "cardId" TEXT NOT NULL,
    "quantity" INTEGER NOT NULL,
    "context" JSONB,
    "completedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "trade_history_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "economy_transactions_userId_createdAt_idx" ON "economy_transactions"("userId", "createdAt");

-- CreateIndex
CREATE INDEX "economy_transactions_tradeId_idx" ON "economy_transactions"("tradeId");

-- CreateIndex
CREATE INDEX "economy_requests_userId_createdAt_idx" ON "economy_requests"("userId", "createdAt");

-- CreateIndex
CREATE INDEX "trades_participantAId_status_idx" ON "trades"("participantAId", "status");

-- CreateIndex
CREATE INDEX "trades_participantBId_status_idx" ON "trades"("participantBId", "status");

-- CreateIndex
CREATE INDEX "trade_items_tradeId_idx" ON "trade_items"("tradeId");

-- CreateIndex
CREATE UNIQUE INDEX "trade_items_tradeId_offeringUserId_cardId_key" ON "trade_items"("tradeId", "offeringUserId", "cardId");

-- CreateIndex
CREATE INDEX "trade_history_tradeId_idx" ON "trade_history"("tradeId");

-- CreateIndex
CREATE INDEX "trade_history_fromUserId_completedAt_idx" ON "trade_history"("fromUserId", "completedAt");

-- CreateIndex
CREATE INDEX "trade_history_toUserId_completedAt_idx" ON "trade_history"("toUserId", "completedAt");

-- AddForeignKey
ALTER TABLE "user_economy" ADD CONSTRAINT "user_economy_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "economy_transactions" ADD CONSTRAINT "economy_transactions_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "economy_requests" ADD CONSTRAINT "economy_requests_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "trades" ADD CONSTRAINT "trades_participantAId_fkey" FOREIGN KEY ("participantAId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "trades" ADD CONSTRAINT "trades_participantBId_fkey" FOREIGN KEY ("participantBId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "trade_items" ADD CONSTRAINT "trade_items_tradeId_fkey" FOREIGN KEY ("tradeId") REFERENCES "trades"("id") ON DELETE CASCADE ON UPDATE CASCADE;

