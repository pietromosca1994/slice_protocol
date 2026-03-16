export class ApiError extends Error {
  constructor(
    public readonly statusCode: number,
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = "ApiError";
  }

  static badRequest(msg: string, details?: unknown) { return new ApiError(400, msg, details); }
  static notFound(msg: string)                      { return new ApiError(404, msg); }
  static readOnly()                                 { return new ApiError(403, "API is running in read-only mode (no ADMIN_SECRET_KEY provided)"); }
  static internal(msg: string, details?: unknown)   { return new ApiError(500, msg, details); }
  static conflict(msg: string)                      { return new ApiError(409, msg); }
}
