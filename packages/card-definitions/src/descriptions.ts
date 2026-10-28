import type { CardDefinition } from '@maailma/game-model';

/**
 * One run of description text sharing a single emphasis.
 *
 * Clients render spans however their UI toolkit prefers — BBCode, HTML, a
 * plain string — so the markup is parsed once, here, into something that
 * needs no further interpretation.
 */
export interface DescriptionSpan {
  text: string;
  bold: boolean;
  italic: boolean;
}

export interface ParsedDescription {
  spans: DescriptionSpan[];
  /** Why the markup is malformed; empty when it is well formed. */
  errors: string[];
}

/**
 * Parses a card description's markup.
 *
 * `**` toggles bold and `*` toggles italic, so `***both***` is bold italic and
 * the two may nest either way round. A backslash makes the next character
 * literal. Anything left open at the end is reported rather than silently
 * running to the end of the card.
 */
export function parseDescription(markup: string): ParsedDescription {
  const spans: DescriptionSpan[] = [];
  let bold = false;
  let italic = false;
  let run = '';

  const flush = () => {
    if (run === '') return;
    const last = spans[spans.length - 1];
    if (last && last.bold === bold && last.italic === italic) last.text += run;
    else spans.push({ text: run, bold, italic });
    run = '';
  };

  for (let index = 0; index < markup.length; index++) {
    const char = markup[index]!;
    if (char === '\\' && index + 1 < markup.length) {
      run += markup[++index];
      continue;
    }
    if (char !== '*') {
      run += char;
      continue;
    }
    flush();
    if (markup[index + 1] === '*') {
      bold = !bold;
      index++;
    } else {
      italic = !italic;
    }
  }
  flush();

  const errors: string[] = [];
  if (bold) errors.push('bold (**) is never closed');
  if (italic) errors.push('italic (*) is never closed');
  return { spans, errors };
}

/** The description with its markup removed, for places that cannot style text. */
export function plainDescription(markup: string): string {
  return parseDescription(markup)
    .spans.map((span) => span.text)
    .join('');
}

/** How a keyword is printed on a card: `LAST_BREATH` → `Last Breath`. */
export function keywordLabel(keyword: string): string {
  return keyword
    .toLowerCase()
    .split('_')
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

/**
 * The keywords a card's description is expected to call out in bold.
 *
 * A Weapon's reach is a property rather than a listed keyword, but Ranged
 * changes how the card plays just as much, so it is printed the same way.
 */
function printedKeywords(card: CardDefinition): string[] {
  if (card.type === 'CREATURE') return [...card.keywords];
  if (card.type === 'WEAPON' && card.range === 'RANGED') return ['RANGED'];
  return [];
}

/**
 * Rejects a description a player could not read correctly.
 *
 * A card with no rules text may leave it blank, but its markup must be
 * balanced and each keyword the card has must appear in bold — the bold is
 * what tells a player "this word is a rule, look it up", so a keyword printed
 * plain reads as flavour, and a card with keywords therefore needs a
 * description. Flavour is optional, but when a card has some its markup is
 * held to the same rule.
 */
export function validateCardDescription(card: CardDefinition): string[] {
  const where = card.id || '(unnamed card)';
  if (typeof card.description !== 'string') {
    return [`${where}: description must be a string`];
  }
  const { spans, errors } = parseDescription(card.description);
  const problems = errors.map((error) => `${where}: description ${error}`);
  const boldText = spans
    .filter((span) => span.bold)
    .map((span) => span.text.toLowerCase())
    .join(' ');
  for (const keyword of printedKeywords(card)) {
    const label = keywordLabel(keyword);
    if (!boldText.includes(label.toLowerCase())) {
      problems.push(`${where}: description must print keyword ${label} in bold`);
    }
  }
  if (card.flavour !== undefined) {
    if (typeof card.flavour !== 'string' || card.flavour.trim() === '') {
      problems.push(`${where}: flavour, when present, must be a non-empty string`);
    } else {
      problems.push(
        ...parseDescription(card.flavour).errors.map((error) => `${where}: flavour ${error}`),
      );
    }
  }
  return problems;
}
