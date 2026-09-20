import { getCardDefinition } from '@maailma/card-definitions';

export interface DeckValidationResult {
  valid: boolean;
  errors: string[];
}

export function validateDeck(cardIds: readonly string[], requiredSize = 30): DeckValidationResult {
  const errors: string[] = [];
  if (cardIds.length !== requiredSize)
    errors.push(`Deck must contain exactly ${requiredSize} cards`);
  const counts = new Map<string, number>();
  for (const cardId of cardIds) {
    try {
      const definition = getCardDefinition(cardId);
      if (!definition.collectible) errors.push(`${definition.name} is not collectible`);
      counts.set(cardId, (counts.get(cardId) ?? 0) + 1);
    } catch {
      errors.push(`Unknown card: ${cardId}`);
    }
  }
  for (const [cardId, count] of counts) {
    const definition = getCardDefinition(cardId);
    const maximum = definition.rarity === 'LEGENDARY' ? 1 : 2;
    if (count > maximum) errors.push(`${definition.name} exceeds its ${maximum}-copy limit`);
  }
  return { valid: errors.length === 0, errors };
}
