-- CreateTable
CREATE TABLE "collection_entries" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "cardId" TEXT NOT NULL,
    "quantity" INTEGER NOT NULL DEFAULT 1,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "collection_entries_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "collection_entries_userId_idx" ON "collection_entries"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "collection_entries_userId_cardId_key" ON "collection_entries"("userId", "cardId");

-- AddForeignKey
ALTER TABLE "collection_entries" ADD CONSTRAINT "collection_entries_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
