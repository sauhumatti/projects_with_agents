import React from 'react';
import { useOrchestrator } from '../context/OrchestratorContext';
import ProjectSelector from './ProjectSelector';
import TaskBoard from './TaskBoard';
import AgentPool from './AgentPool';
import PMChat from './PMChat';
import ActivityLog from './ActivityLog';

export default function Dashboard() {
  const { selectedProject, tasks, loading, messages, refreshData } = useOrchestrator();

  // Calculate progress stats
  const totalTasks = tasks.length;
  const completedTasks = tasks.filter(t =>
    t.currentStatus === 'completed' || t.currentStatus === 'approved' || t.status === 'completed'
  ).length;
  const runningTasks = tasks.filter(t => t.currentStatus === 'running').length;
  const pendingMessages = messages.length;

  const progressPercent = totalTasks > 0 ? Math.round((completedTasks / totalTasks) * 100) : 0;

  return (
    <div className="min-h-screen flex flex-col">
      {/* Header */}
      <header className="bg-orchestrator-dark border-b border-gray-800 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-6">
            <h1 className="text-xl font-bold text-white flex items-center gap-2">
              <svg className="w-6 h-6 text-blue-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z" />
              </svg>
              Orchestrator
            </h1>
            <ProjectSelector />
          </div>

          <div className="flex items-center gap-4">
            {/* Progress indicator */}
            {totalTasks > 0 && (
              <div className="flex items-center gap-3">
                <div className="text-sm text-gray-400">
                  {completedTasks}/{totalTasks} tasks
                </div>
                <div className="w-32 h-2 bg-gray-700 rounded-full overflow-hidden">
                  <div
                    className="h-full bg-green-500 transition-all duration-500"
                    style={{ width: `${progressPercent}%` }}
                  />
                </div>
                <div className="text-sm font-medium text-white">{progressPercent}%</div>
              </div>
            )}

            {/* Quick stats */}
            <div className="flex items-center gap-3 pl-4 border-l border-gray-700">
              {runningTasks > 0 && (
                <span className="px-2 py-1 bg-yellow-900/50 text-yellow-400 rounded text-sm flex items-center gap-1">
                  <span className="w-2 h-2 bg-yellow-500 rounded-full animate-pulse" />
                  {runningTasks} running
                </span>
              )}
              {pendingMessages > 0 && (
                <span className="px-2 py-1 bg-red-900/50 text-red-400 rounded text-sm flex items-center gap-1">
                  <span className="w-2 h-2 bg-red-500 rounded-full animate-pulse" />
                  {pendingMessages} pending
                </span>
              )}
            </div>

            {/* Refresh button */}
            <button
              onClick={refreshData}
              className="p-2 hover:bg-gray-800 rounded-lg transition-colors"
              title="Refresh data"
            >
              <svg className="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
              </svg>
            </button>
          </div>
        </div>
      </header>

      {/* Main content */}
      <div className="flex-1 flex overflow-hidden">
        {/* Left panel - Task Board */}
        <div className="flex-1 overflow-auto p-6">
          {loading ? (
            <div className="flex items-center justify-center h-64">
              <div className="text-gray-400">Loading...</div>
            </div>
          ) : !selectedProject ? (
            <div className="flex items-center justify-center h-64">
              <div className="text-center">
                <h2 className="text-xl font-semibold text-gray-400 mb-2">No Project Selected</h2>
                <p className="text-gray-500">Select a project from the dropdown above</p>
              </div>
            </div>
          ) : (
            <TaskBoard />
          )}
        </div>

        {/* Right sidebar */}
        <div className="w-96 border-l border-gray-800 flex flex-col bg-orchestrator-dark">
          {/* PM Chat */}
          <div className="flex-1 border-b border-gray-800 overflow-hidden flex flex-col">
            <PMChat />
          </div>

          {/* Agent Pool */}
          <div className="h-48 border-b border-gray-800 overflow-hidden">
            <AgentPool />
          </div>

          {/* Activity Log */}
          <div className="h-64 overflow-hidden">
            <ActivityLog />
          </div>
        </div>
      </div>
    </div>
  );
}
