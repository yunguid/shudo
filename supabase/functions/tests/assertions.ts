export function assert(
  condition: unknown,
  message = "Expected condition to be truthy",
): asserts condition {
  if (!condition) throw new Error(message);
}

export function assertEquals<T>(actual: T, expected: T): void {
  if (Object.is(actual, expected)) return;
  const actualJSON = JSON.stringify(actual);
  const expectedJSON = JSON.stringify(expected);
  if (actualJSON !== expectedJSON) {
    throw new Error(`Expected ${expectedJSON}, received ${actualJSON}`);
  }
}

export function assertThrows(
  action: () => unknown,
  expectedStatus?: number,
  messageIncludes?: string,
): Error {
  try {
    action();
  } catch (error) {
    if (!(error instanceof Error)) throw error;
    if (
      expectedStatus !== undefined &&
      (error as Error & { status?: number }).status !== expectedStatus
    ) {
      throw new Error(
        `Expected status ${expectedStatus}, received ${
          (error as Error & { status?: number }).status
        }`,
      );
    }
    if (messageIncludes && !error.message.includes(messageIncludes)) {
      throw new Error(
        `Expected error containing ${messageIncludes}, received ${error.message}`,
      );
    }
    return error;
  }
  throw new Error("Expected action to throw");
}
