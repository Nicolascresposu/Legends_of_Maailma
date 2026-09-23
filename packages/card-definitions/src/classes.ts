import type { CardDefinition, ClassDefinition } from '@maailma/game-model';

export const CLASS_DEFINITIONS: Readonly<Record<string, ClassDefinition>> = Object.freeze({
  WIZARD: Object.freeze({ id: 'WIZARD', name: 'Wizard' }),
  PRIEST: Object.freeze({ id: 'PRIEST', name: 'Priest' }),
});

export function isKnownClass(classId: string): boolean {
  return Object.hasOwn(CLASS_DEFINITIONS, classId);
}

export function getClassDefinition(classId: string): ClassDefinition {
  const definition = CLASS_DEFINITIONS[classId];
  if (!definition) throw new Error(`Unknown class definition: ${classId}`);
  return definition;
}

/** A card with no class is neutral: every class's decks may hold it. */
export function isNeutralCard(card: CardDefinition): boolean {
  return card.classId === undefined;
}

/** Whether a deck of `classId` may hold this card. */
export function cardFitsClass(card: CardDefinition, classId: string): boolean {
  return isNeutralCard(card) || card.classId === classId;
}
