// What the packed executable starts: the harness's command line, nothing else. There is no
// guard here on purpose — inside a binary there is no source file to compare against.
import { run } from "./server.mjs";

run();
