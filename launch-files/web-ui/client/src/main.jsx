import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import { OrchestratorProvider } from './context/OrchestratorContext'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <OrchestratorProvider>
        <App />
      </OrchestratorProvider>
    </BrowserRouter>
  </React.StrictMode>,
)
