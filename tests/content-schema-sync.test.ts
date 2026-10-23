import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { CLASS_DEFINITIONS } from '@maailma/card-definitions';

describe('Godot authoring schema', () => {
  it('ships the current server schema and class IDs in desktop exports', () => {
    const source = readFileSync(
      new URL('../apps/godot-client/src/content_schema.gd', import.meta.url),
      'utf8',
    );
    const [schema, classes] = source.split('const SCHEMA = ')[1]!.split('\n\nconst CLASSES = ');
    const canonical = JSON.parse(
      readFileSync(
        new URL('../packages/card-definitions/content.schema.json', import.meta.url),
        'utf8',
      ),
    );
    expect(JSON.parse(schema!)).toEqual(canonical);
    expect(JSON.parse(classes!)).toEqual(Object.keys(CLASS_DEFINITIONS).sort());
  });
});
