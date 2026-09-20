export class GameRuleError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'GameRuleError';
  }
}

export function rule(condition: unknown, code: string, message: string): asserts condition {
  if (!condition) throw new GameRuleError(code, message);
}
