// Import the public entry point to include all existing registry/domain checks.
import { CARD_DEFINITIONS, EXPANSION_DEFINITIONS, PACK_DEFINITIONS } from './index.js';

console.log(
  `Content valid: ${Object.keys(EXPANSION_DEFINITIONS).length} expansions, ` +
    `${Object.keys(CARD_DEFINITIONS).length} cards, ${Object.keys(PACK_DEFINITIONS).length} packs.`,
);
