import http from 'http';
import moment from 'moment';
import { app } from './app';
import { DemoServer } from './demo-server';
import { DiskTranscriptStore } from './transcript-store';

const { PORT = 80, YOU_INDICIES = '', STORE_PATH = '../store' } = process.env;

async function main() {
  const transcriptStore = new DiskTranscriptStore(STORE_PATH);
  const youIndicies = YOU_INDICIES.split(',').map(i => +i);
  const demoServer = new DemoServer(50, moment().add(5, 's'), transcriptStore, youIndicies);
  demoServer.start();

  const httpServer = http.createServer(app(demoServer).callback());
  httpServer.listen(PORT);
  console.log(`Server listening on port ${PORT}.`);

  const shutdown = async () => {
    console.log('Shutting down.');
    demoServer.stop();
    await new Promise(resolve => httpServer.close(resolve));
    console.log('Shutdown complete.');
  };

  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

main().catch(console.error);
