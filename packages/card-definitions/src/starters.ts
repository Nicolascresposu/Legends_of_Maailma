import type { CardDefinition, CardType, ScenarioDefinition } from '@maailma/game-model';
import { CLASS_DEFINITIONS, cardFitsClass, isKnownClass } from './classes.js';
import { isKnownHero } from './heroes.js';

/**
 * The deck a new account is given for one class, and the deck a side plays
 * when it brings none. Content, like the cards it lists, so renaming a card
 * in the creator can follow every reference to it.
 */
export interface StarterDeckDefinition {
  id: string;
  name: string;
  classId: string;
  expansionId: string;
  cards: Array<{ cardId: string; copies: number }>;
}

/** A scenario as authored: the definition the engine plays, and the expansion that ships it. */
export interface ScenarioContent extends ScenarioDefinition {
  expansionId: string;
}

/** A starter deck as the list of card ids a deck is saved with. */
export function starterDeckCards(deck: StarterDeckDefinition): string[] {
  return deck.cards.flatMap((entry) => Array<string>(entry.copies).fill(entry.cardId));
}

/** The scenario the engine plays, without the authoring fields it never reads. */
export function scenarioDefinition(scenario: ScenarioContent): ScenarioDefinition {
  const definition: Partial<ScenarioContent> = { ...scenario };
  delete definition.expansionId;
  return definition as ScenarioDefinition;
}

/**
 * Starter decks name cards by id and belong to a class. Every class needs
 * exactly one, and every card in it must be one a new account can own and
 * that class may play.
 */
export function validateStarterDecks(
  decks: readonly StarterDeckDefinition[],
  cards: ReadonlyMap<string, CardDefinition>,
  locate: (deck: StarterDeckDefinition) => string,
): string[] {
  const errors: string[] = [];
  const byClass = new Map<string, StarterDeckDefinition[]>();
  for (const deck of decks) {
    const where = `${locate(deck)}: ${deck.id}`;
    if (!isKnownClass(deck.classId)) errors.push(`${where}: unknown class "${deck.classId}"`);
    byClass.set(deck.classId, [...(byClass.get(deck.classId) ?? []), deck]);
    const listed = new Set<string>();
    for (const { cardId, copies } of deck.cards) {
      if (listed.has(cardId)) errors.push(`${where}: lists "${cardId}" more than once`);
      listed.add(cardId);
      const card = cards.get(cardId);
      if (!card) {
        errors.push(`${where}: unknown card "${cardId}"`);
        continue;
      }
      if (!card.collectible) errors.push(`${where}: ${cardId} is not collectible`);
      if (!cardFitsClass(card, deck.classId)) {
        errors.push(`${where}: ${cardId} is a ${card.classId} card, not ${deck.classId}`);
      }
      if (card.rarity === 'LEGENDARY' && copies > 1) {
        errors.push(`${where}: ${cardId} is Legendary, so the deck may hold only one`);
      }
    }
  }
  for (const classId of Object.keys(CLASS_DEFINITIONS)) {
    const found = byClass.get(classId) ?? [];
    if (found.length === 0) errors.push(`class ${classId}: has no starter deck`);
    if (found.length > 1) {
      errors.push(
        `class ${classId}: has ${found.length} starter decks (${found.map((deck) => deck.id).join(', ')})`,
      );
    }
  }
  return errors;
}

const TYPE_NAMES: Record<CardType, string> = {
  CREATURE: 'a Creature',
  ACTION: 'an Action',
  WEAPON: 'a Weapon',
  ARTIFACT: 'an Artifact',
  LOCATION: 'a Location',
};

/** Scenarios name Heroes, and cards each side starts with, by id. */
export function validateScenarios(
  scenarios: readonly ScenarioContent[],
  cards: ReadonlyMap<string, CardDefinition>,
  locate: (scenario: ScenarioContent) => string,
): string[] {
  const errors: string[] = [];
  for (const scenario of scenarios) {
    for (const [sideName, side] of [
      ['sideA', scenario.sideA],
      ['sideB', scenario.sideB],
    ] as const) {
      const where = `${locate(scenario)}: ${scenario.id}.${sideName}`;
      if (!isKnownHero(side.heroDefinitionId)) {
        errors.push(`${where}: unknown hero "${side.heroDefinitionId}"`);
      }
      const expect = (cardId: string, type?: CardType) => {
        const card = cards.get(cardId);
        if (!card) errors.push(`${where}: unknown card "${cardId}"`);
        else if (type && card.type !== type) {
          errors.push(`${where}: ${cardId} must be ${TYPE_NAMES[type]}`);
        }
      };
      for (const id of side.startingCards ?? []) expect(id);
      for (const { definitionId } of side.startingCreatures ?? []) expect(definitionId, 'CREATURE');
      for (const { definitionId } of side.startingLocations ?? []) expect(definitionId, 'LOCATION');
      for (const id of side.startingArtifacts ?? []) expect(id, 'ARTIFACT');
      if (side.startingWeapon) expect(side.startingWeapon, 'WEAPON');
    }
  }
  return errors;
}
