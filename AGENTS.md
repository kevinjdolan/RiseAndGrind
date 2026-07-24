# Repository Agent Guidance

## Connected iPhone Deployment

- When the user says "send to my phone", treat it as a request to build the current `RiseAndGrind` app, sign it for the connected physical iPhone, install it on that device, and verify that installation succeeded.
- Detect the connected device instead of assuming a device identifier. Use the `RiseAndGrind` scheme and the signing configuration already defined by the project.
- Preserve the user's source changes. Put derived build products outside the repository, and do not modify signing settings merely to complete a routine device deployment.
- If deployment cannot proceed because the iPhone must be unlocked, trusted, or placed in Developer Mode, report that concrete blocker and the smallest action the user needs to take.
