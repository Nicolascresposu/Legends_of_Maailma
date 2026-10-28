import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import {
  CLASS_DEFINITIONS,
  getCardDefinition,
  getExpansionDefinition,
  getPackDefinition,
} from '@maailma/card-definitions';
import type { CreatureDefinition, Effect } from '@maailma/game-model';
import { loadContent } from '../packages/card-definitions/src/content.js';

let root: string;

function fixture(id = 'TEST') {
  return {
    expansion: { schemaVersion: 1, ...structuredClone(getExpansionDefinition('CORE')), id },
    cards: [
      {
        ...structuredClone(getCardDefinition('chicken') as CreatureDefinition),
        id: `${id}_wolf`,
        expansionId: id,
      },
    ],
    packs: [
      { ...structuredClone(getPackDefinition('CORE_PACK')), id: `${id}_PACK`, expansionId: id },
    ],
  };
}

function writeFixture(data = fixture(), folder = 'test') {
  const directory = join(root, folder);
  mkdirSync(directory, { recursive: true });
  for (const [name, value] of Object.entries(data)) {
    writeFileSync(join(directory, `${name}.json`), JSON.stringify(value));
  }
}

/**
 * Gives `folder` one starter deck per class, built from `cardId`: a catalogue
 * is only complete with them, so every load that should succeed needs one.
 */
function writeStarters(folder = 'test', cardId = 'TEST_wolf', expansionId = 'TEST') {
  const decks = Object.keys(CLASS_DEFINITIONS).map((classId) => ({
    id: `${classId}_STARTER`,
    name: `${classId} starter`,
    classId,
    expansionId,
    cards: [{ cardId, copies: 2 }],
  }));
  writeFileSync(join(root, folder, 'starterDecks.json'), JSON.stringify(decks));
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'maailma-content-'));
});

afterEach(() => {
  // Only remove this test's freshly created temporary content directory.
  if (!root.startsWith(join(tmpdir(), 'maailma-content-'))) throw new Error('Unexpected temp path');
  rmSync(root, { recursive: true, force: true });
});

describe('JSON expansion discovery', () => {
  it('discovers new expansion folders with no TypeScript registration', () => {
    writeFixture(fixture('SECOND'), 'z-second');
    writeFixture(fixture('FIRST'), 'a-first');
    writeStarters('a-first', 'FIRST_wolf', 'FIRST');
    const loaded = loadContent(pathToFileURL(root));
    expect(loaded.expansions.map((expansion) => expansion.id)).toEqual(['FIRST', 'SECOND']);
    expect(loaded.cards.map((card) => card.id)).toEqual(['FIRST_wolf', 'SECOND_wolf']);
    expect(loaded.packs.map((pack) => pack.id)).toEqual(['FIRST_PACK', 'SECOND_PACK']);
    expect(loaded.expansions[0]).not.toHaveProperty('schemaVersion');
  });

  it('supports an unfinished expansion with no cards or packs', () => {
    const data = fixture();
    data.expansion.policy.released = false;
    data.cards = [];
    data.packs = [];
    writeFixture(data);
    // The starter decks live in a finished expansion beside it.
    writeFixture(fixture('OTHER'), 'other');
    writeStarters('other', 'OTHER_wolf', 'OTHER');
    const unfinished = loadContent(root).expansions.find((expansion) => expansion.id === 'TEST');
    expect(unfinished?.policy.released).toBe(false);
  });

  it('loads compiled registries from a different working directory', () => {
    const entry = new URL('../packages/card-definitions/dist/index.js', import.meta.url).href;
    const output = execFileSync(
      process.execPath,
      [
        '--input-type=module',
        '-e',
        `const {getCardDefinition} = await import(${JSON.stringify(entry)}); console.log(getCardDefinition('chicken').name);`,
      ],
      { cwd: root, encoding: 'utf8' },
    );
    expect(output.trim()).toBe('Chicken');
  });

  it('reports a missing file with its path', () => {
    mkdirSync(join(root, 'unfinished'));
    expect(() => loadContent(root)).toThrow(/unfinished.*expansion\.json/);
  });

  it('reports malformed JSON with its path', () => {
    writeFixture();
    writeFileSync(join(root, 'test/cards.json'), '[{');
    expect(() => loadContent(root)).toThrow(/cards\.json/);
  });

  it('rejects an empty content directory', () => {
    expect(() => loadContent(root)).toThrow('no expansion folders found');
  });
});

describe('content shape validation', () => {
  it.each([
    [
      'missing policy flag',
      (data: any) => {
        delete data.expansion.policy.released;
      },
      /released/,
    ],
    [
      'unsupported schema version',
      (data: any) => {
        data.expansion.schemaVersion = 2;
      },
      /schemaVersion/,
    ],
    [
      'unknown card type',
      (data: any) => {
        data.cards[0].type = 'SPELL';
      },
      /type/,
    ],
    [
      'unknown keyword',
      (data: any) => {
        data.cards[0].keywords = ['FLYING'];
      },
      /keywords/,
    ],
    [
      'misspelled field',
      (data: any) => {
        data.cards[0].heath = 2;
      },
      /heath/,
    ],
    [
      'missing creature health',
      (data: any) => {
        delete data.cards[0].health;
      },
      /health/,
    ],
    [
      'string cost',
      (data: any) => {
        data.cards[0].cost = '2';
      },
      /cost/,
    ],
    [
      'fractional health',
      (data: any) => {
        data.cards[0].health = 1.5;
      },
      /health/,
    ],
    [
      'negative cost',
      (data: any) => {
        data.cards[0].cost = -1;
      },
      /cost/,
    ],
    [
      'unknown rarity',
      (data: any) => {
        data.cards[0].rarity = 'MYTHIC';
      },
      /rarity/,
    ],
    [
      'unknown effect',
      (data: any) => {
        data.cards[0].effects = [{ trigger: 'ARRIVAL', effect: { type: 'WIN' } }];
      },
      /type/,
    ],
    [
      'missing effect target',
      (data: any) => {
        data.cards[0].effects = [{ trigger: 'ARRIVAL', effect: { type: 'HEAL', amount: 2 } }];
      },
      /target/,
    ],
    [
      'unknown effect target',
      (data: any) => {
        data.cards[0].effects = [
          { trigger: 'ARRIVAL', effect: { type: 'HEAL', amount: 2, target: 'EVERYONE' } },
        ];
      },
      /target/,
    ],
    [
      'unknown trigger',
      (data: any) => {
        data.cards[0].effects = [{ trigger: 'ON_CLICK', effect: { type: 'DRAW_CARD', amount: 1 } }];
      },
      /trigger/,
    ],
    [
      'negative pack slot count',
      (data: any) => {
        data.packs[0].rarityRules.slots[0].count = -1;
      },
      /count/,
    ],
    [
      'negative rarity weight',
      (data: any) => {
        data.packs[0].rarityRules.slots[0].weights.COMMON = -1;
      },
      /COMMON/,
    ],
    [
      'Basic pack weight',
      (data: any) => {
        data.packs[0].rarityRules.slots[0].weights.BASIC = 1;
      },
      /BASIC/,
    ],
    [
      'empty rarity weights',
      (data: any) => {
        data.packs[0].rarityRules.slots[0].weights = {};
      },
      /weights/,
    ],
    [
      'wrong root type',
      (data: any) => {
        data.cards = {};
      },
      /array/,
    ],
    [
      'null card',
      (data: any) => {
        data.cards = [null];
      },
      /object/,
    ],
  ])('rejects %s with a file and field diagnostic', (_name, change, message) => {
    const data = fixture();
    change(data);
    writeFixture(data);
    expect(() => loadContent(root)).toThrow(message);
    expect(() => loadContent(root)).toThrow(/\.json/);
  });

  it('accepts every supported effect shape, including cross-expansion summons', () => {
    const data = fixture();
    const effects: Effect[] = [
      { type: 'DEAL_DAMAGE', amount: 1, target: 'PLAY_TARGET' },
      { type: 'HEAL', amount: 1, target: 'OWNER_HERO' },
      { type: 'DRAW_CARD', amount: 1 },
      { type: 'BUFF', attack: -1, health: 0, target: 'SELF' },
      { type: 'APPLY_STATUS', status: 'ROOTED', duration: 1, target: 'PLAY_TARGET' },
      { type: 'SUMMON', definitionId: 'OTHER_wolf', position: { row: 'BACK', column: 0 } },
      { type: 'MOVE', target: 'SELF', destination: { row: 'FRONT', column: 1 } },
      { type: 'DESTROY', target: 'ENEMY_WEAPON' },
      { type: 'GAIN_TAIKA', amount: 1 },
    ];
    data.cards[0]!.effects = effects.map((effect) => ({ trigger: 'ARRIVAL', effect }));
    writeFixture(data);
    writeFixture(fixture('OTHER'), 'other');
    writeStarters();
    expect(loadContent(root).cards.find((card) => card.id === 'TEST_wolf')?.effects).toEqual(
      data.cards[0]!.effects,
    );
  });

  it('carries an art credit, which must not be blank when given', () => {
    const data = fixture();
    data.cards[0]!.artist = 'Russell Dongjun Lu';
    writeFixture(data);
    writeStarters();
    expect(loadContent(root).cards.find((card) => card.id === 'TEST_wolf')?.artist).toBe(
      'Russell Dongjun Lu',
    );
    data.cards[0]!.artist = ' ';
    writeFixture(data);
    expect(() => loadContent(root)).toThrow(/artist/);
  });
});

describe('content references and semantic validation', () => {
  it.each(['expansion', 'cards', 'packs'] as const)(
    'rejects duplicate %s IDs across files',
    (kind) => {
      const first = fixture();
      const second = fixture('OTHER');
      if (kind === 'expansion') second.expansion.id = first.expansion.id;
      else second[kind][0]!.id = first[kind][0]!.id;
      writeFixture(first);
      writeFixture(second, 'other');
      expect(() => loadContent(root)).toThrow(/duplicate id/);
    },
  );

  it('rejects duplicate IDs within a file', () => {
    const data = fixture();
    data.cards.push(structuredClone(data.cards[0]!));
    writeFixture(data);
    expect(() => loadContent(root)).toThrow(/duplicate id/);
  });

  it.each(['cards', 'packs'] as const)('rejects %s assigned to another expansion', (kind) => {
    const data = fixture();
    data[kind][0]!.expansionId = 'MISSING';
    writeFixture(data);
    expect(() => loadContent(root)).toThrow(/expansionId must be "TEST"/);
  });

  it('rejects unknown classes and malformed printed text', () => {
    const data = fixture();
    data.cards[0]!.classId = 'MISSING';
    data.cards[0]!.description = '**Unclosed';
    writeFixture(data);
    expect(() => loadContent(root)).toThrow(/unknown class/);
    expect(() => loadContent(root)).toThrow(/never closed/);
  });

  it('rejects a summon referring to a missing card or a non-Creature', () => {
    const data = fixture();
    data.cards[0]!.effects = [
      { trigger: 'ARRIVAL', effect: { type: 'SUMMON', definitionId: 'MISSING' } },
    ];
    writeFixture(data);
    expect(() => loadContent(root)).toThrow(/SUMMON must reference an existing Creature/);
    writeFileSync(
      join(root, 'test/cards.json'),
      JSON.stringify([
        data.cards[0],
        { ...getCardDefinition('firebolt'), id: 'MISSING', expansionId: 'TEST' },
      ]),
    );
    expect(() => loadContent(root)).toThrow(/SUMMON must reference an existing Creature/);
  });

  it('rejects pack counts that disagree with the slot rules', () => {
    const data = fixture();
    data.packs[0]!.cardCount = 9;
    writeFixture(data);
    expect(() => loadContent(root)).toThrow(/slot rules cover 5 cards but the pack holds 9/);
  });
});
