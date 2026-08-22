const admin = require('firebase-admin');

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

async function updateRequest() {
  const requestRef = db.collection('service_requests').doc('req_test_001');

  await requestRef.update({
    status: 'accepted',
    assigned_provider_id: 'provider_001',
    assigned_provider_name: 'City Hospital',
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log(`Success: updated service_requests/${requestRef.id}`);
}

updateRequest()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Failed to update test request:', error);
    process.exit(1);
  });
