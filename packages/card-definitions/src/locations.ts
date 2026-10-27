import type { LocationDefinition, Trigger } from '@maailma/game-model';

/**
 * Triggers a Location can answer. It is placed rather than summoned and
 * crumbles rather than dies, so Arrival and Last Breath would never fire.
 */
const LOCATION_TRIGGERS: readonly Trigger[] = ['TURN_STARTED', 'TURN_ENDED'];

/**
 * Rejects a Location whose measures disagree with what it does.
 *
 * The schema checks each field alone; this checks them together. A Location
 * with neither Durability nor a duration would stand for ever, one with
 * Durability but nothing to activate would be a wall with a counter on it,
 * and one with an activation but no Durability could never use it.
 */
export function validateLocationDefinition(definition: LocationDefinition): string[] {
  const errors: string[] = [];
  const where = definition.id || '(unnamed location)';
  const { durability, duration, activation } = definition;
  if (durability === undefined && duration === undefined)
    errors.push(`${where}: a Location needs a durability, a duration or both`);
  if (durability !== undefined && (!Number.isInteger(durability) || durability < 1))
    errors.push(`${where}: durability must be a positive integer`);
  if (duration !== undefined && (!Number.isInteger(duration) || duration < 1))
    errors.push(`${where}: duration must be a positive integer`);
  if (durability !== undefined && !activation)
    errors.push(`${where}: a Location with durability needs an activation`);
  if (activation && durability === undefined)
    errors.push(`${where}: a Location with an activation needs durability to spend`);
  if (activation) {
    if (activation.effects.length === 0)
      errors.push(`${where}: activation must have at least one effect`);
    const aimed = activation.effects.some(
      (effect) => 'target' in effect && effect.target === 'PLAY_TARGET',
    );
    if (aimed && activation.targetMode === 'NONE')
      errors.push(`${where}: an activation aimed at PLAY_TARGET needs a targetMode`);
  }
  for (const entry of definition.effects) {
    if (!LOCATION_TRIGGERS.includes(entry.trigger))
      errors.push(`${where}: a Location's effects trigger on ${LOCATION_TRIGGERS.join(' or ')}`);
  }
  return errors;
}
