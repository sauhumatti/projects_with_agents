import React from 'react';
import { Routes, Route } from 'react-router-dom';
import Dashboard from './components/Dashboard';
import { useOrchestrator } from './context/OrchestratorContext';

function App() {
  const { connected, loading, error } = useOrchestrator();

  if (error) {
    return (
      <div className="min-h-screen bg-orchestrator-darker flex items-center justify-center">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-red-500 mb-2">Error</h1>
          <p className="text-gray-400">{error}</p>
          <button
            onClick={() => window.location.reload()}
            className="mt-4 px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-orchestrator-darker">
      {/* Connection status indicator */}
      <div className={`fixed top-2 right-2 z-50 flex items-center gap-2 px-3 py-1 rounded-full text-xs ${
        connected ? 'bg-green-900/50 text-green-400' : 'bg-red-900/50 text-red-400'
      }`}>
        <span className={`w-2 h-2 rounded-full ${connected ? 'bg-green-500' : 'bg-red-500 animate-pulse'}`} />
        {connected ? 'Connected' : 'Disconnected'}
      </div>

      <Routes>
        <Route path="/" element={<Dashboard />} />
      </Routes>
    </div>
  );
}

export default App;
