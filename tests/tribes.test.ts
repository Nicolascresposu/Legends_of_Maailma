import { describe, expect, it } from 'vitest';
import {
  CARD_DEFINITIONS,
  EXPANSION_DEFINITIONS,
  contentDocuments,
  currentContent,
  parseContentDocuments,
  validateLocationDefinition,
} from '@maailma/card-definitions';
import { GameEngine, heroEntityId } from '@maailma/game-engine';
import type {
  ActionDefinition,
  CardDefinition,
  CreatureDefinition,
  GameAction,
  LocationDefinition,
  Position,
} from '@maailma/game-model';
import { MatchManager } from '../apps/server/src/match-manager.js';
import { matchRandomPool } from '../apps/server/src/services/expansion-service.js';
import { creatureId, makeEngine } from './helpers.js';

const base = {
  source: 'CORE',
  expansionId: 'CORE',
  rarity: 'COMMON',
  collectible: true,
  description: 'Test card.',
} as const;

const creature = (id: string, extra: Partial<CreatureDefinition> = {}): CreatureDefinition => ({
  ...base,
  id,
  name: id,
  type: 'CREATURE',
  cost: 1,
  attack: 1,
  health: 1,
  tags: [],
  keywords: [],
  effects: [],
  ...extra,
});

const action = (id: string, extra: Partial<ActionDefinition> = {}): ActionDefinition => ({
  ...base,
  id,
  name: id,
  type: 'ACTION',
  cost: 1,
  targetMode: 'NONE',
  effects: [],
  ...extra,
});

const TEST_CARDS: CardDefinition[] = [
  action('pack_howl', {
    effects: [
      { type: 'BUFF', attack: 1, health: 1, target: 'ALL_FRIENDLY_CREATURES', tag: 'BEAST' },
    ],
  }),
  action('beast_snipe', {
    effects: [{ type: 'DEAL_DAMAGE', amount: 5, target: 'RANDOM_ENEMY_CREATURE', tag: 'BEAST' }],
  }),
  action('beast_bait', {
    targetMode: 'FRIENDLY_CREATURE',
    targetTag: 'BEAST',
    effects: [{ type: 'BUFF', attack: 2, health: 2, target: 'PLAY_TARGET' }],
  }),
  action('smite', {
    targetMode: 'ANY_CHARACTER',
    effects: [{ type: 'DEAL_DAMAGE', amount: 1, target: 'PLAY_TARGET' }],
  }),
  action('execute', {
    targetMode: 'ANY_CHARACTER',
    effects: [{ type: 'DEAL_DAMAGE', amount: 10, target: 'PLAY_TARGET' }],
  }),
  creature('beastmaster', {
    effects: [
      {
        trigger: 'ARRIVAL',
        effect: { type: 'BUFF', attack: 2, health: 2, target: 'PLAY_TARGET', tag: 'BEAST' },
      },
    ],
  }),
  creature('hunt_caller', {
    effects: [{ trigger: 'ARRIVAL', effect: { type: 'SUMMON_RANDOM', tag: 'TEST_DRAKE' } }],
  }),
  creature('horn_blower', {
    effects: [{ trigger: 'ARRIVAL', effect: { type: 'SUMMON', definitionId: 'hunt_caller' } }],
  }),
  creature('drake_a', { tags: ['TEST_DRAKE'] }),
  creature('drake_b', { tags: ['TEST_DRAKE'] }),
  creature('drake_token', { tags: ['TEST_DRAKE'], collectible: false }),
  creature('pack_leader', {
    tags: ['BEAST'],
    effects: [
      {
        trigger: 'ARRIVAL',
        effect: {
          type: 'BUFF',
          attack: 2,
          health: 2,
          target: 'SELF',
          condition: { type: 'CONTROLS_CREATURE', tag: 'BEAST' },
        },
      },
    ],
  }),
  creature('drake_whisperer', {
    effects: [
      {
        trigger: 'ARRIVAL',
        effect: {
          type: 'DRAW_CARD',
          amount: 1,
          condition: { type: 'HOLDS_CARD', tag: 'TEST_DRAKE' },
        },
      },
    ],
  }),
  creature('kennel_master', {
    tags: ['BEAST'],
    effects: [
      {
        trigger: 'FRIENDLY_CREATURE_SUMMONED',
        tag: 'BEAST',
        effect: { type: 'BUFF', attack: 1, health: 0, target: 'TRIGGERING_CREATURE' },
      },
    ],
  }),
  creature('grave_hound', {
    health: 5,
    effects: [
      {
        trigger: 'FRIENDLY_CREATURE_DIED',
        tag: 'BEAST',
        effect: { type: 'DEAL_DAMAGE', amount: 1, target: 'ENEMY_HERO' },
      },
    ],
  }),
  creature('alpha', {
    tags: ['BEAST'],
    health: 2,
    auras: [
      { type: 'STAT_AURA', attack: 1, health: 1, target: 'OTHER_FRIENDLY_CREATURES', tag: 'BEAST' },
    ],
  }),
  creature('den_mother', {
    auras: [{ type: 'COST_AURA', amount: -1, tag: 'BEAST' }],
  }),
  creature('great_den', {
    auras: [{ type: 'COST_AURA', amount: -5, tag: 'BEAST', cardType: 'CREATURE' }],
  }),
];

const content = {
  version: 'tribes-test',
  cards: {
    ...CARD_DEFINITIONS,
    ...Object.fromEntries(TEST_CARDS.map((card) => [card.id, card])),
  },
};

/** Enough to draw from every turn, so no Hero takes fatigue damage. */
const WOLVES = Array<string>(20).fill('chicken');

const at = (column: number, row: Position['row'] = 'FRONT'): Position => ({ row, column });

function engineWith(
  a: Array<[string, number]> = [],
  b: Array<[string, number]> = [],
  seed: number | string = 123,
): GameEngine {
  return makeEngine({
    content,
    seed,
    deckA: WOLVES,
    deckB: WOLVES,
    a: a.map(([definitionId, column]) => ({ definitionId, position: at(column) })),
    b: b.map(([definitionId, column]) => ({ definitionId, position: at(column) })),
  });
}

function giveCard(engine: GameEngine, definitionId: string): string {
  const side = engine.state.sides.a!;
  const instanceId = `given_${definitionId}_${side.hand.length}`;
  side.hand.push({ instanceId, definitionId });
  return instanceId;
}

function play(
  engine: GameEngine,
  definitionId: string,
  aim: { position?: Position; targetId?: string } = {},
) {
  const cardInstanceId = giveCard(engine, definitionId);
  return engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId, ...aim });
}

const stats = (engine: GameEngine, playerId: 'a' | 'b', definitionId: string) => {
  const found =
    engine.state.sides[playerId]!.creatures[creatureId(engine, playerId, definitionId)]!;
  return [found.currentAttack, found.currentHealth, found.maxHealth];
};

const playsOf = (engine: GameEngine, cardInstanceId: string) =>
  engine
    .getLegalActions('a')
    .filter(
      (candidate): candidate is Extract<GameAction, { type: 'PLAY_CARD' }> =>
        candidate.type === 'PLAY_CARD' && candidate.cardInstanceId === cardInstanceId,
    );

describe('tags narrowing effects', () => {
  it('reaches only friendly Creatures carrying the tag', () => {
    const engine = engineWith([
      ['chicken', 0],
      ['human_mercenary', 1],
    ]);
    expect(play(engine, 'pack_howl').ok).toBe(true);
    expect(stats(engine, 'a', 'chicken')).toEqual([3, 2, 2]);
    expect(stats(engine, 'a', 'human_mercenary')).toEqual([3, 2, 2]);
  });

  it('picks at random only among Creatures carrying the tag', () => {
    for (const seed of [1, 2, 3, 4, 5]) {
      const engine = engineWith(
        [],
        [
          ['human_mercenary', 0],
          ['elf_archer', 1],
          ['chicken', 2],
        ],
        seed,
      );
      expect(play(engine, 'beast_snipe').ok).toBe(true);
      const survivors = Object.values(engine.state.sides.b!.creatures).map((c) => c.definitionId);
      expect(survivors.sort()).toEqual(['elf_archer', 'human_mercenary']);
    }
  });
});

describe('plays aimed at a tag', () => {
  it('offers and accepts only Creatures carrying the tag', () => {
    const engine = engineWith([
      ['chicken', 0],
      ['human_mercenary', 1],
    ]);
    const card = giveCard(engine, 'beast_bait');
    expect(playsOf(engine, card).map((play) => play.targetId)).toEqual([
      creatureId(engine, 'a', 'chicken'),
    ]);
    const wrong = engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId: card,
      targetId: creatureId(engine, 'a', 'human_mercenary'),
    });
    expect(wrong.error?.code).toBe('INVALID_TARGET');
  });

  it('keeps an Action in hand when nothing carries the tag', () => {
    const engine = engineWith([['human_mercenary', 0]]);
    expect(playsOf(engine, giveCard(engine, 'beast_bait'))).toEqual([]);
  });

  it('lets a Creature arrive with nothing to aim at, but makes it aim when it can', () => {
    const lonely = engineWith([['human_mercenary', 0]]);
    const card = giveCard(lonely, 'beastmaster');
    expect(playsOf(lonely, card).every((play) => play.targetId === undefined)).toBe(true);
    expect(
      lonely.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId: card, position: at(1) })
        .ok,
    ).toBe(true);

    const engine = engineWith([['chicken', 0]]);
    const aimed = giveCard(engine, 'beastmaster');
    const wolf = creatureId(engine, 'a', 'chicken');
    expect(new Set(playsOf(engine, aimed).map((play) => play.targetId))).toEqual(new Set([wolf]));
    expect(
      engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId: aimed, position: at(1) })
        .error?.code,
    ).toBe('TARGET_REQUIRED');
    expect(
      engine.dispatch({
        type: 'PLAY_CARD',
        actorId: 'a',
        cardInstanceId: aimed,
        position: at(1),
        targetId: wolf,
      }).ok,
    ).toBe(true);
    expect(stats(engine, 'a', 'chicken')).toEqual([4, 3, 3]);
  });
});

describe('random summons', () => {
  it('summons a collectible Creature carrying the tag, the same one for the same seed', () => {
    const summoned = (seed: number) => {
      const engine = engineWith([], [], seed);
      expect(play(engine, 'hunt_caller', { position: at(0) }).ok).toBe(true);
      return Object.values(engine.state.sides.a!.creatures)
        .map((c) => c.definitionId)
        .filter((id) => id !== 'hunt_caller');
    };
    const picks = [1, 2, 3, 4, 5, 6, 7, 8].map((seed) => summoned(seed));
    for (const pick of picks) expect(['drake_a', 'drake_b']).toContain(pick[0]);
    expect(picks.flat()).not.toContain('drake_token');
    expect(summoned(3)).toEqual(summoned(3));
  });

  it('sets off Arrival only for a Creature played from hand, not one summoned', () => {
    const engine = engineWith();
    expect(play(engine, 'horn_blower', { position: at(0) }).ok).toBe(true);
    const board = Object.values(engine.state.sides.a!.creatures).map((c) => c.definitionId);
    expect(board.sort()).toEqual(['horn_blower', 'hunt_caller']);
  });

  it('sends the client every Creature a random summon could bring', () => {
    const engine = makeEngine({ content, deckA: ['hunt_caller'] });
    const ids = engine.presentationCards().map((card) => card.id);
    expect(ids).toEqual(expect.arrayContaining(['drake_a', 'drake_b']));
    expect(ids).not.toContain('drake_token');
  });

  it('draws only from the setup’s random pool, and sends only that pool', () => {
    const setup = structuredClone(engineWith().setup);
    setup.randomPool = ['drake_b', 'hunt_caller', 'chicken'];
    setup.players[0].deck = ['hunt_caller'];
    for (const seed of [1, 2, 3, 4, 5, 6]) {
      const engine = new GameEngine({ ...setup, seed });
      expect(play(engine, 'hunt_caller', { position: at(0) }).ok).toBe(true);
      const summoned = Object.values(engine.state.sides.a!.creatures).map((c) => c.definitionId);
      expect(summoned.sort()).toEqual(['drake_b', 'hunt_caller']);
    }
    const ids = new GameEngine(setup).presentationCards().map((card) => card.id);
    expect(ids).toContain('drake_b');
    expect(ids).not.toContain('drake_a');
  });

  it('refuses a random pool naming a card the match does not have', () => {
    const setup = structuredClone(engineWith().setup);
    setup.randomPool = ['no_such_card'];
    expect(() => new GameEngine(setup)).toThrow(/no_such_card/);
  });
});

describe('server random pools', () => {
  const request = {
    scenarioId: 'STANDARD_PVP',
    players: [{ playerId: 'p1' }, { playerId: 'p2' }],
  } as const;

  it('leaves unreleased expansions out by default', () => {
    const pool = new MatchManager().create(structuredClone(request)).setup.randomPool!;
    expect(pool).toContain('lio_varga');
    // Machines of Kona ships unreleased.
    expect(pool).not.toContain('kona_riveter');
    expect(pool).toEqual(matchRandomPool(EXPANSION_DEFINITIONS));
  });

  it('takes the pool it is given, and keeps it when an open seat is claimed', () => {
    const manager = new MatchManager();
    const engine = manager.createWithOpenSeat(
      { scenarioId: 'STANDARD_PVP', creator: { playerId: 'p1' } },
      { randomPool: ['kona_riveter', 'chicken'] },
    );
    expect(engine.setup.randomPool).toEqual(['kona_riveter', 'chicken']);
    const claimed = manager.claimSeat(engine.state.matchId, { playerId: 'p2' });
    expect(claimed.setup.randomPool).toEqual(['kona_riveter', 'chicken']);
  });
});

describe('conditions', () => {
  it('counts other matching Creatures, never the source itself', () => {
    const alone = engineWith();
    expect(play(alone, 'pack_leader', { position: at(0) }).ok).toBe(true);
    expect(stats(alone, 'a', 'pack_leader')).toEqual([1, 1, 1]);

    const withPack = engineWith([['chicken', 0]]);
    expect(play(withPack, 'pack_leader', { position: at(1) }).ok).toBe(true);
    expect(stats(withPack, 'a', 'pack_leader')).toEqual([3, 3, 3]);
  });

  it('looks in the hand for a matching card', () => {
    const handSize = (engine: GameEngine) => engine.state.sides.a!.hand.length;
    const without = engineWith();
    const before = handSize(without);
    expect(play(without, 'drake_whisperer', { position: at(0) }).ok).toBe(true);
    expect(handSize(without)).toBe(before);

    const holding = engineWith();
    giveCard(holding, 'drake_a');
    const held = handSize(holding);
    expect(play(holding, 'drake_whisperer', { position: at(0) }).ok).toBe(true);
    expect(handSize(holding)).toBe(held + 1);
  });
});

describe('reactions to other Creatures', () => {
  it('answers a matching friendly summon, aimed at the Creature summoned', () => {
    const engine = engineWith([['kennel_master', 0]]);
    expect(play(engine, 'chicken', { position: at(1) }).ok).toBe(true);
    expect(play(engine, 'human_mercenary', { position: at(2) }).ok).toBe(true);
    expect(stats(engine, 'a', 'chicken')).toEqual([3, 1, 1]);
    expect(stats(engine, 'a', 'human_mercenary')).toEqual([3, 2, 2]);
  });

  it('does not answer its own arrival', () => {
    const engine = engineWith();
    expect(play(engine, 'kennel_master', { position: at(0) }).ok).toBe(true);
    expect(stats(engine, 'a', 'kennel_master')).toEqual([1, 1, 1]);
  });

  it('answers a matching friendly death', () => {
    const engine = engineWith([
      ['grave_hound', 0],
      ['chicken', 1],
      ['human_mercenary', 2],
    ]);
    const enemyHero = () => engine.state.sides.b!.hero.currentHealth;
    const before = enemyHero();
    expect(
      play(engine, 'execute', { targetId: creatureId(engine, 'a', 'human_mercenary') }).ok,
    ).toBe(true);
    expect(enemyHero()).toBe(before);
    expect(play(engine, 'execute', { targetId: creatureId(engine, 'a', 'chicken') }).ok).toBe(true);
    expect(enemyHero()).toBe(before - 1);
  });
});

describe('auras', () => {
  it('lends matching Creatures its bonus for as long as it stands', () => {
    const engine = engineWith([
      ['alpha', 0],
      ['chicken', 1],
      ['human_mercenary', 2],
    ]);
    expect(stats(engine, 'a', 'chicken')).toEqual([3, 2, 2]);
    expect(stats(engine, 'a', 'alpha')).toEqual([1, 2, 2]);
    expect(stats(engine, 'a', 'human_mercenary')).toEqual([3, 2, 2]);

    expect(play(engine, 'hawk', { position: at(0, 'BACK') }).ok).toBe(true);
    expect(stats(engine, 'a', 'hawk')).toEqual([3, 2, 2]);

    expect(play(engine, 'execute', { targetId: creatureId(engine, 'a', 'alpha') }).ok).toBe(true);
    expect(stats(engine, 'a', 'chicken')).toEqual([2, 1, 1]);
    expect(stats(engine, 'a', 'hawk')).toEqual([2, 1, 1]);
    const wolf = engine.state.sides.a!.creatures[creatureId(engine, 'a', 'chicken')]!;
    expect(wolf.auraBonus).toBeUndefined();
  });

  it('wounds but never kills when it leaves', () => {
    const engine = engineWith([
      ['alpha', 0],
      ['chicken', 1],
    ]);
    expect(play(engine, 'smite', { targetId: creatureId(engine, 'a', 'chicken') }).ok).toBe(true);
    expect(stats(engine, 'a', 'chicken')).toEqual([3, 1, 2]);
    expect(play(engine, 'execute', { targetId: creatureId(engine, 'a', 'alpha') }).ok).toBe(true);
    expect(stats(engine, 'a', 'chicken')).toEqual([2, 1, 1]);
  });

  it('discounts matching cards in hand, never below 0, and charges the discounted cost', () => {
    const engine = engineWith([['den_mother', 0]]);
    const bear = giveCard(engine, 'brown_bear');
    giveCard(engine, 'chicken');
    giveCard(engine, 'human_mercenary');
    expect(engine.dispatch({ type: 'END_TURN', actorId: 'a' }).ok).toBe(true);
    expect(engine.dispatch({ type: 'END_TURN', actorId: 'b' }).ok).toBe(true);

    const side = engine.state.sides.a!;
    const costOf = (definitionId: string) =>
      side.hand.find((card) => card.definitionId === definitionId)!.cost;
    expect(costOf('brown_bear')).toBe(2);
    expect(costOf('chicken')).toBe(0);
    expect(costOf('human_mercenary')).toBeUndefined();

    const taika = side.taika.current;
    expect(
      engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId: bear, position: at(1) })
        .ok,
    ).toBe(true);
    expect(side.taika.current).toBe(taika - 2);

    expect(play(engine, 'execute', { targetId: creatureId(engine, 'a', 'den_mother') }).ok).toBe(
      true,
    );
    expect(costOf('chicken')).toBeUndefined();
  });

  it('applies only to the card type it names', () => {
    const engine = engineWith([['great_den', 0]]);
    const bear = giveCard(engine, 'brown_bear');
    const taika = engine.state.sides.a!.taika.current;
    expect(
      engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId: bear, position: at(1) })
        .ok,
    ).toBe(true);
    expect(engine.state.sides.a!.taika.current).toBe(taika);
  });
});

describe('determinism', () => {
  it('replays tag rules, auras and random summons to the same state', () => {
    const setup = structuredClone(engineWith([['alpha', 0]], [], 'tribes').setup);
    setup.scenario.sideA.startingCards = ['hunt_caller', 'den_mother'];
    const engine = new GameEngine(setup);
    for (const [definitionId, column] of [
      ['den_mother', 1],
      ['hunt_caller', 2],
    ] as const) {
      const card = engine.state.sides.a!.hand.find((entry) => entry.definitionId === definitionId)!;
      const played = engine.dispatch({
        type: 'PLAY_CARD',
        actorId: 'a',
        cardInstanceId: card.instanceId,
        position: at(column),
      });
      expect(played.ok, played.error?.message).toBe(true);
    }
    expect(engine.dispatch({ type: 'END_TURN', actorId: 'a' }).ok).toBe(true);
    const replayed = GameEngine.replay({ setup, actions: engine.state.actionLog });
    expect(replayed.state).toEqual(engine.state);
  });
});

describe('tag rule validation', () => {
  const withCard = (card: CardDefinition) => () => {
    const documents = contentDocuments(currentContent()).map((data) => ({
      folder: data.expansion.id,
      data: data.expansion.id === 'CORE' ? { ...data, cards: [...data.cards, card] } : data,
    }));
    return parseContentDocuments(documents);
  };

  it('accepts tags that some card carries', () => {
    expect(withCard(TEST_CARDS.find((card) => card.id === 'pack_howl')!)).not.toThrow();
  });

  it('rejects a tag no card carries, which is almost always a typo', () => {
    const typo = action('typo', {
      effects: [
        { type: 'BUFF', attack: 1, health: 1, target: 'ALL_FRIENDLY_CREATURES', tag: 'BEEST' },
      ],
    });
    expect(withCard(typo)).toThrow(/no card carries tag "BEEST"/);
  });

  it('rejects a tag on a target that is never a Creature', () => {
    const heroic = action('heroic', {
      effects: [{ type: 'HEAL', amount: 1, target: 'OWNER_HERO', tag: 'BEAST' }],
    });
    expect(withCard(heroic)).toThrow(/cannot narrow OWNER_HERO/);
  });

  it('rejects TRIGGERING_CREATURE outside a trigger that has one', () => {
    const lost = creature('lost', {
      effects: [
        {
          trigger: 'ARRIVAL',
          effect: { type: 'BUFF', attack: 1, health: 1, target: 'TRIGGERING_CREATURE' },
        },
      ],
    });
    expect(withCard(lost)).toThrow(/TRIGGERING_CREATURE needs/);
  });

  it('rejects an aura that changes nothing', () => {
    const idle = creature('idle', { auras: [{ type: 'COST_AURA', amount: 0 }] });
    expect(withCard(idle)).toThrow(/COST_AURA must change the cost/);
  });

  it('lets a Location answer the Creatures beside it', () => {
    const kennel: LocationDefinition = {
      ...base,
      id: 'kennel',
      name: 'Kennel',
      type: 'LOCATION',
      cost: 2,
      duration: 3,
      effects: [
        {
          trigger: 'FRIENDLY_CREATURE_DIED',
          tag: 'BEAST',
          effect: { type: 'HEAL', amount: 2, target: 'OWNER_HERO' },
        },
      ],
    };
    expect(validateLocationDefinition(kennel)).toEqual([]);
    expect(withCard(kennel)).not.toThrow();
  });
});

it('still treats a Hero as a legal target when no tag narrows it', () => {
  const engine = engineWith();
  const card = giveCard(engine, 'smite');
  expect(playsOf(engine, card).map((play) => play.targetId)).toContain(heroEntityId('b'));
});
