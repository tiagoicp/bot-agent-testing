import { beforeAll, afterAll } from "bun:test";
import { PocketIcServer } from "@dfinity/pic";

let pic: PocketIcServer | undefined;

beforeAll(async () => {
  pic = await PocketIcServer.start();
  const url = pic.getUrl();

  process.env.PIC_URL = url;
}, 10000);

afterAll(async () => {
  await pic?.stop();
});
