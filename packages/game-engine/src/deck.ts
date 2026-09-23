import { CLASS_DEFINITIONS, cardFitsClass, getCardDefinition } from '@maailma/card-definitions';
import type { DeckFormat, Rarity } from '@maailma/game-model';

export interface DeckValidationResult {
  valid: boolean;
  errors: string[];
}

/**
 * How many copies of one card a deck may hold.
 *
 * The single source for the rule. Duplicate protection asks the same question
 * when deciding whether a player still needs a card, so the two must never be
 * able to drift: a "playset" means the same thing to a deck builder and to a
 * pack.
 */
export function deckCopyLimit(rarity: Rarity): number {
  return rarity === 'LEGENDARY' ? 1 : 2;
}

/** The copy limit for a card id, or 0 when the registry does not define it. */
export function cardCopyLimit(cardId: string): number {
  try {
    return deckCopyLimit(getCardDefinition(cardId).rarity);
  } catch {
    return 0;
  }
}

/**
 * Which expansions a format admits, supplied by the caller.
 *
 * The engine deliberately does not read policy itself: policies are live
 * server state, and an engine that reached for them would make a match's
 * legality depend on a database the engine has no business knowing about.
 * Callers with policy in hand pass this in; callers without it — replays,
 * unit tests, PvE scenarios — omit it and get the format-agnostic rules.
 */
export type FormatLegality = (cardId: string, format: DeckFormat) => boolean;

export interface DeckValidationOptions {
  requiredSize?: number;
  /**
   * The class the deck is played as — its hero's class. Omitted, class is not
   * checked; given, every class card must belong to it.
   */
  classId?: string;
  /** The format to judge against. Omitted, format legality is not checked. */
  format?: DeckFormat;
  /** Answers whether a card's expansion is admitted by that format. */
  isLegalInFormat?: FormatLegality;
}

export function validateDeck(
  cardIds: readonly string[],
  optionsOrSize: DeckValidationOptions | number = {},
): DeckValidationResult {
  const options: DeckValidationOptions =
    typeof optionsOrSize === 'number' ? { requiredSize: optionsOrSize } : optionsOrSize;
  const requiredSize = options.requiredSize ?? 30;

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
    const maximum = deckCopyLimit(definition.rarity);
    if (count > maximum) errors.push(`${definition.name} exceeds its ${maximum}-copy limit`);
  }

  // Named per card, like format legality: "Firebolt is a Wizard card" tells a
  // player what to take out, where "wrong class" alone would not.
  if (options.classId !== undefined) {
    const deckClass = CLASS_DEFINITIONS[options.classId]?.name ?? options.classId;
    const foreign = [...counts.keys()]
      .filter((cardId) => !cardFitsClass(getCardDefinition(cardId), options.classId!))
      .sort();
    for (const cardId of foreign) {
      const definition = getCardDefinition(cardId);
      const cardClass = CLASS_DEFINITIONS[definition.classId!]?.name ?? definition.classId;
      errors.push(
        `${definition.name} is a ${cardClass} card and cannot be played in a ${deckClass} deck`,
      );
    }
  }

  // Format legality is reported per card rather than as one verdict, so a
  // client can name what rotated rather than only that something did.
  const { format, isLegalInFormat } = options;
  if (format && isLegalInFormat) {
    const illegal = [...counts.keys()].filter((cardId) => !isLegalInFormat(cardId, format)).sort();
    for (const cardId of illegal) {
      const definition = getCardDefinition(cardId);
      errors.push(`${definition.name} is not legal in ${format}`);
    }
  }

  return { valid: errors.length === 0, errors };
}
