import type { CardDefinition, Effect, EffectTarget, Trigger } from '@maailma/game-model';

/** Targets that never reach a Creature, so a `tag` on them could only ever match nothing. */
const CREATURELESS_TARGETS: readonly EffectTarget[] = [
  'OWNER_HERO',
  'ENEMY_HERO',
  'FRIENDLY_WEAPON',
  'ENEMY_WEAPON',
];

/** Triggers that fire for another Creature, which is what they may filter and aim at. */
const CREATURE_TRIGGERS: readonly Trigger[] = [
  'FRIENDLY_CREATURE_SUMMONED',
  'FRIENDLY_CREATURE_DIED',
];

/**
 * Rejects tag rules that are well formed field by field but could never work.
 *
 * The schema checks each field alone; this checks them together. A tag on an
 * effect aimed at a Hero, `TRIGGERING_CREATURE` outside a trigger that has a
 * triggering Creature, or an aura that changes nothing would all load fine
 * and then quietly do nothing in play.
 */
export function validateTagRules(card: CardDefinition): string[] {
  const where = card.id || '(unnamed card)';
  const errors: string[] = [];
  const checkEffect = (effect: Effect, trigger?: Trigger) => {
    if (!('target' in effect)) return;
    if (effect.tag !== undefined && CREATURELESS_TARGETS.includes(effect.target))
      errors.push(
        `${where}: tag "${effect.tag}" cannot narrow ${effect.target}, which is never a Creature`,
      );
    if (
      effect.target === 'TRIGGERING_CREATURE' &&
      !(trigger && CREATURE_TRIGGERS.includes(trigger))
    )
      errors.push(
        `${where}: TRIGGERING_CREATURE needs a ${CREATURE_TRIGGERS.join(' or ')} trigger`,
      );
  };
  if (card.type === 'ACTION') {
    for (const effect of card.effects) checkEffect(effect);
    if (card.targetTag !== undefined && card.targetMode === 'NONE')
      errors.push(`${where}: targetTag needs a targetMode other than NONE`);
  } else {
    for (const entry of card.effects) {
      checkEffect(entry.effect, entry.trigger);
      if (entry.tag !== undefined && !CREATURE_TRIGGERS.includes(entry.trigger))
        errors.push(`${where}: a trigger's tag only filters ${CREATURE_TRIGGERS.join(' or ')}`);
    }
  }
  if (card.type === 'LOCATION' && card.activation) {
    for (const effect of card.activation.effects) checkEffect(effect);
    if (card.activation.targetTag !== undefined && card.activation.targetMode === 'NONE')
      errors.push(`${where}: activation targetTag needs a targetMode other than NONE`);
  }
  if (card.type === 'CREATURE' || card.type === 'ARTIFACT' || card.type === 'LOCATION') {
    for (const aura of card.auras ?? []) {
      if (aura.type === 'COST_AURA' && aura.amount === 0)
        errors.push(`${where}: a COST_AURA must change the cost, but its amount is 0`);
      if (aura.type === 'STAT_AURA' && aura.attack === 0 && aura.health === 0)
        errors.push(`${where}: a STAT_AURA must give some attack or health`);
    }
  }
  return errors;
}
