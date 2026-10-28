import type { HeroDefinition } from '@maailma/game-model';
import { isKnownClass } from './classes.js';

export const HERO_DEFINITIONS: Readonly<Record<string, HeroDefinition>> = Object.freeze({
  healer: {
    id: 'healer',
    name: 'The Mender',
    classId: 'PRIEST',
    health: 30,
    power: {
      id: 'mend',
      name: 'Mend',
      cost: 2,
      text: 'Restore 2 Health to your Hero.',
      targetMode: 'NONE',
      effect: { type: 'HEAL', amount: 2, target: 'OWNER_HERO' },
    },
  },
  striker: {
    id: 'striker',
    name: 'The Striker',
    classId: 'WIZARD',
    health: 30,
    power: {
      id: 'strike',
      name: 'Strike',
      cost: 2,
      text: 'Deal 1 damage to the enemy Hero.',
      targetMode: 'NONE',
      effect: { type: 'DEAL_DAMAGE', amount: 1, target: 'ENEMY_HERO' },
    },
  },
});

// A hero's class decides which cards its decks may hold, so a typo here is
// caught at import rather than when someone picks that hero.
const heroErrors = Object.values(HERO_DEFINITIONS)
  .filter((hero) => !isKnownClass(hero.classId))
  .map((hero) => `hero ${hero.id}: unknown class "${hero.classId}"`);
if (heroErrors.length > 0) {
  throw new Error(`Invalid hero definitions: ${heroErrors.join('; ')}`);
}

export function isKnownHero(heroId: string): boolean {
  return Object.hasOwn(HERO_DEFINITIONS, heroId);
}

export function getHeroDefinition(id: string): HeroDefinition {
  const definition = HERO_DEFINITIONS[id];
  if (!definition) throw new Error(`Unknown hero definition: ${id}`);
  return definition;
}

/** The class a hero belongs to, and so the class of any deck built for it. */
export function heroClassId(heroId: string): string {
  return getHeroDefinition(heroId).classId;
}
