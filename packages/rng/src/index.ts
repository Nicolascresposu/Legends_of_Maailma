/** A small, serializable PRNG suitable for deterministic simulation (Mulberry32). */
export class SeededRng {
  private value: number;

  constructor(seed: number | string) {
    this.value = normalizeSeed(seed);
  }

  static fromState(state: number): SeededRng {
    const rng = new SeededRng(0);
    rng.value = state >>> 0;
    return rng;
  }

  get state(): number {
    return this.value >>> 0;
  }

  next(): number {
    this.value = (this.value + 0x6d2b79f5) >>> 0;
    let result = this.value;
    result = Math.imul(result ^ (result >>> 15), result | 1);
    result ^= result + Math.imul(result ^ (result >>> 7), result | 61);
    return ((result ^ (result >>> 14)) >>> 0) / 4_294_967_296;
  }

  int(maxExclusive: number): number {
    if (!Number.isInteger(maxExclusive) || maxExclusive <= 0) {
      throw new Error('maxExclusive must be a positive integer');
    }
    return Math.floor(this.next() * maxExclusive);
  }

  pick<T>(items: readonly T[]): T {
    if (items.length === 0) throw new Error('Cannot pick from an empty collection');
    return items[this.int(items.length)]!;
  }

  shuffle<T>(items: readonly T[]): T[] {
    const result = [...items];
    for (let index = result.length - 1; index > 0; index -= 1) {
      const swapIndex = this.int(index + 1);
      [result[index], result[swapIndex]] = [result[swapIndex]!, result[index]!];
    }
    return result;
  }
}

export function normalizeSeed(seed: number | string): number {
  if (typeof seed === 'number') return seed >>> 0;
  let hash = 2166136261;
  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}
