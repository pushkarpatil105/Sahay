const admin = require('firebase-admin');

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

async function writeRequest() {
  const requestRef = db.collection('service_requests').doc('req_test_001');

  await requestRef.set({
    request_id: 'req_test_001',
    user_id: 'user_test',
    user_name: 'Test User',
    service_type: 'ambulance',
    status: 'pending',
    location: {lat: 22.7196, lng: 75.8577},
    assigned_provider_id: null,
    assigned_provider_name: null,
    is_demo: true,
    escalation_count: 0,
    created_at: admin.firestore.FieldValue.serverTimestamp(),
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log(`Success: created service_requests/${requestRef.id}`);
}

writeRequest()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Failed to create test request:', error);
    process.exit(1);
  });
