const admin = require('firebase-admin');

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();
const query = db.collection('service_requests').where('is_demo', '==', true);

console.log('Listening for demo service requests. Press Ctrl+C to stop.');

const unsubscribe = query.onSnapshot(
  (snapshot) => {
    snapshot.docChanges().forEach((change) => {
      console.log(`\n${change.type.toUpperCase()}: service_requests/${change.doc.id}`);
      console.dir(change.doc.data(), {depth: null});
    });
  },
  (error) => {
    console.error('Firestore listener failed:', error);
    process.exit(1);
  },
);

process.on('SIGINT', () => {
  console.log('\nStopping Firestore listener...');
  unsubscribe();
  process.exit(0);
});
