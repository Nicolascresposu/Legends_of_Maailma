import { describe, expect, it } from 'vitest';
import {
  CARD_DEFINITIONS,
  getCardDefinition,
  keywordLabel,
  parseDescription,
  plainDescription,
  validateCardDescription,
} from '@maailma/card-definitions';
import type { CardDefinition } from '@maailma/game-model';

describe('description markup', () => {
  it('reads bold and italic runs', () => {
    expect(parseDescription('**Guard**\n*Hold the line.*').spans).toEqual([
      { text: 'Guard', bold: true, italic: false },
      { text: '\n', bold: false, italic: false },
      { text: 'Hold the line.', bold: false, italic: true },
    ]);
  });

  it('nests bold and italic in either order', () => {
    expect(parseDescription('***both***').spans).toEqual([
      { text: 'both', bold: true, italic: true },
    ]);
    expect(parseDescription('*a **b** c*').spans).toEqual([
      { text: 'a ', bold: false, italic: true },
      { text: 'b', bold: true, italic: true },
      { text: ' c', bold: false, italic: true },
    ]);
  });

  it('treats a backslash-escaped asterisk as text', () => {
    const parsed = parseDescription('Deal 2\\*3 damage.');
    expect(parsed.errors).toEqual([]);
    expect(plainDescription('Deal 2\\*3 damage.')).toBe('Deal 2*3 damage.');
  });

  it('reports emphasis left open', () => {
    expect(parseDescription('**Guard').errors).toEqual(['bold (**) is never closed']);
    expect(parseDescription('*flavour').errors).toEqual(['italic (*) is never closed']);
  });

  it('strips markup for plain-text contexts', () => {
    expect(plainDescription('**Arrival:** Draw a card.\n*Once.*')).toBe(
      'Arrival: Draw a card.\nOnce.',
    );
  });

  it('prints keywords the way a player reads them', () => {
    expect(keywordLabel('GUARD')).toBe('Guard');
    expect(keywordLabel('LAST_BREATH')).toBe('Last Breath');
  });
});

describe('card descriptions', () => {
  it.each(Object.values(CARD_DEFINITIONS).map((card) => [card.id, card] as const))(
    '%s has a readable description',
    (_id, card) => {
      expect(validateCardDescription(card)).toEqual([]);
      expect(plainDescription(card.description).trim()).not.toBe('');
      // Descriptions are rules only; story lives in `flavour`.
      expect(parseDescription(card.description).spans.some((span) => span.italic)).toBe(false);
      expect(card.flavour?.trim()).toBeTruthy();
    },
  );

  it('rejects malformed flavour markup', () => {
    const card: CardDefinition = { ...getCardDefinition('wolf'), flavour: '**loud' };
    expect(validateCardDescription(card)).toEqual(['wolf: flavour bold (**) is never closed']);
  });

  it('allows a card with no flavour', () => {
    const card = { ...getCardDefinition('wolf') };
    delete card.flavour;
    expect(validateCardDescription(card)).toEqual([]);
  });

  it('rejects a keyword printed without bold', () => {
    const plain: CardDefinition = { ...getCardDefinition('dwarf_defender'), description: 'Guard' };
    expect(validateCardDescription(plain)).toEqual([
      'dwarf_defender: description must print keyword Guard in bold',
    ]);
  });

  it('treats a Ranged Weapon as carrying the Ranged keyword', () => {
    const bow: CardDefinition = { ...getCardDefinition('hunting_bow'), description: '*A bow.*' };
    expect(validateCardDescription(bow)).toEqual([
      'hunting_bow: description must print keyword Ranged in bold',
    ]);
  });

  it('rejects a missing description', () => {
    const blank: CardDefinition = { ...getCardDefinition('wolf'), description: '  ' };
    expect(validateCardDescription(blank)).toEqual([
      'wolf: description must be a non-empty string',
    ]);
  });
});
