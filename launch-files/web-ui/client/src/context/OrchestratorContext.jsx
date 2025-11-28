import React, { createContext, useContext, useReducer, useEffect, useCallback } from 'react';
import { useWebSocket } from '../hooks/useWebSocket';

const OrchestratorContext = createContext(null);

const initialState = {
  connected: false,
  selectedProject: null,
  projects: [],
  tasks: [],
  agents: {},
  pool: {},
  messages: [],
  logs: [],
  loading: true,
  error: null,
};

function reducer(state, action) {
  switch (action.type) {
    case 'SET_CONNECTED':
      return { ...state, connected: action.payload };

    case 'SET_PROJECTS':
      return { ...state, projects: action.payload, loading: false };

    case 'SELECT_PROJECT':
      return { ...state, selectedProject: action.payload };

    case 'SET_TASKS':
      return { ...state, tasks: action.payload };

    case 'UPDATE_TASK': {
      const { taskId, updates } = action.payload;
      return {
        ...state,
        tasks: state.tasks.map(t =>
          t.id === taskId ? { ...t, ...updates } : t
        ),
      };
    }

    case 'SET_AGENTS':
      return { ...state, agents: action.payload };

    case 'SET_POOL':
      return { ...state, pool: action.payload };

    case 'UPDATE_POOL': {
      return {
        ...state,
        pool: { ...state.pool, ...action.payload },
      };
    }

    case 'SET_MESSAGES':
      return { ...state, messages: action.payload };

    case 'ADD_MESSAGE':
      return {
        ...state,
        messages: [action.payload, ...state.messages],
      };

    case 'REMOVE_MESSAGE':
      return {
        ...state,
        messages: state.messages.filter(m => m.id !== action.payload),
      };

    case 'ADD_LOG':
      return {
        ...state,
        logs: [action.payload, ...state.logs].slice(0, 100),
      };

    case 'SET_LOGS':
      return { ...state, logs: action.payload };

    case 'SET_ERROR':
      return { ...state, error: action.payload, loading: false };

    case 'SET_LOADING':
      return { ...state, loading: action.payload };

    default:
      return state;
  }
}

export function OrchestratorProvider({ children }) {
  const [state, dispatch] = useReducer(reducer, initialState);

  // WebSocket connection
  const { sendMessage, isConnected } = useWebSocket({
    onMessage: (event) => {
      console.log('WS Event:', event.type, event);

      switch (event.type) {
        case 'connected':
          dispatch({ type: 'SET_CONNECTED', payload: true });
          break;

        case 'tasks:update':
          if (!state.selectedProject || event.project === state.selectedProject) {
            dispatch({ type: 'SET_TASKS', payload: event.tasks });
          }
          break;

        case 'task:running':
        case 'task:completed':
        case 'task:approved':
        case 'task:stopped':
          dispatch({
            type: 'UPDATE_TASK',
            payload: {
              taskId: event.taskId,
              updates: {
                currentStatus: event.type.split(':')[1],
                ...event.status,
              },
            },
          });
          dispatch({
            type: 'ADD_LOG',
            payload: {
              timestamp: event.timestamp,
              level: 'INFO',
              message: `Task ${event.taskId}: ${event.type.split(':')[1]}`,
            },
          });
          break;

        case 'pool:update':
          dispatch({ type: 'UPDATE_POOL', payload: event.agents });
          break;

        case 'agents:status':
          dispatch({ type: 'SET_AGENTS', payload: event.agents });
          break;

        case 'pm:question':
          dispatch({ type: 'ADD_MESSAGE', payload: event.message });
          break;

        case 'user:response':
          dispatch({ type: 'REMOVE_MESSAGE', payload: event.messageId });
          break;

        case 'agent:messages':
          dispatch({
            type: 'ADD_LOG',
            payload: {
              timestamp: event.timestamp,
              level: 'INFO',
              message: `${event.messages.length} agent message(s) pending`,
            },
          });
          break;

        default:
          console.log('Unhandled event:', event.type);
      }
    },
    onConnect: () => {
      dispatch({ type: 'SET_CONNECTED', payload: true });
    },
    onDisconnect: () => {
      dispatch({ type: 'SET_CONNECTED', payload: false });
    },
  });

  // Fetch projects on mount
  useEffect(() => {
    fetchProjects();
  }, []);

  // Fetch project data when selected
  useEffect(() => {
    if (state.selectedProject) {
      fetchProjectData(state.selectedProject);
    }
  }, [state.selectedProject]);

  const fetchProjects = useCallback(async () => {
    try {
      const res = await fetch('/api/projects');
      const data = await res.json();
      dispatch({ type: 'SET_PROJECTS', payload: data.projects || [] });

      // Auto-select first project if none selected
      if (data.projects?.length > 0 && !state.selectedProject) {
        dispatch({ type: 'SELECT_PROJECT', payload: data.projects[0].name });
      }
    } catch (e) {
      console.error('Failed to fetch projects:', e);
      dispatch({ type: 'SET_ERROR', payload: e.message });
    }
  }, [state.selectedProject]);

  const fetchProjectData = useCallback(async (projectName) => {
    try {
      dispatch({ type: 'SET_LOADING', payload: true });

      const [tasksRes, agentsRes, messagesRes, logsRes] = await Promise.all([
        fetch(`/api/tasks?project=${projectName}`),
        fetch(`/api/agents?project=${projectName}`),
        fetch(`/api/messages?project=${projectName}&pending=true`),
        fetch(`/api/logs?project=${projectName}&limit=50`),
      ]);

      const [tasksData, agentsData, messagesData, logsData] = await Promise.all([
        tasksRes.json(),
        agentsRes.json(),
        messagesRes.json(),
        logsRes.json(),
      ]);

      dispatch({ type: 'SET_TASKS', payload: tasksData.tasks || [] });
      dispatch({ type: 'SET_AGENTS', payload: agentsData.status || {} });
      dispatch({ type: 'SET_POOL', payload: agentsData.pool || {} });
      dispatch({ type: 'SET_MESSAGES', payload: messagesData.messages || [] });
      dispatch({ type: 'SET_LOGS', payload: logsData.logs || [] });
      dispatch({ type: 'SET_LOADING', payload: false });
    } catch (e) {
      console.error('Failed to fetch project data:', e);
      dispatch({ type: 'SET_ERROR', payload: e.message });
    }
  }, []);

  const selectProject = useCallback((projectName) => {
    dispatch({ type: 'SELECT_PROJECT', payload: projectName });
  }, []);

  const respondToMessage = useCallback(async (messageId, response) => {
    try {
      const res = await fetch(`/api/messages/${messageId}/respond`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          response,
          project: state.selectedProject,
        }),
      });

      if (res.ok) {
        dispatch({ type: 'REMOVE_MESSAGE', payload: messageId });
        return true;
      }
      return false;
    } catch (e) {
      console.error('Failed to respond:', e);
      return false;
    }
  }, [state.selectedProject]);

  const refreshData = useCallback(() => {
    if (state.selectedProject) {
      fetchProjectData(state.selectedProject);
    }
  }, [state.selectedProject, fetchProjectData]);

  const value = {
    ...state,
    isConnected,
    selectProject,
    respondToMessage,
    refreshData,
    fetchProjects,
  };

  return (
    <OrchestratorContext.Provider value={value}>
      {children}
    </OrchestratorContext.Provider>
  );
}

export function useOrchestrator() {
  const context = useContext(OrchestratorContext);
  if (!context) {
    throw new Error('useOrchestrator must be used within OrchestratorProvider');
  }
  return context;
}
